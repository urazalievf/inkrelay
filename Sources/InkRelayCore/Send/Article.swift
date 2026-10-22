import Foundation

/// A web page reduced to what's worth reading on e-ink: title, byline, the article's own text and pictures.
public struct Article: Equatable {
    public var title: String
    public var byline: String?
    public var sourceURL: URL?
    /// XHTML body content, with images referenced as `images/<name>`.
    public var bodyXHTML: String
    public var images: [EmbeddedImage]

    public struct EmbeddedImage: Equatable {
        public var name: String
        public var mediaType: String
        public var data: Data
    }
}

#if os(macOS)
/// Finds the article in a page: the `<article>`, `<main>` or block with the most paragraph text,
/// minus navigation, ads, scripts and forms. Pictures are downloaded and embedded.
public enum ArticleExtractor {
    static let dropped = ["script", "style", "nav", "header", "footer", "aside", "form", "iframe", "noscript", "svg", "button", "input", "select", "template", "dialog", "menu"]
    static let blocks: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "figure", "figcaption", "hr", "dl", "dt", "dd"]
    static let inline: Set<String> = ["em", "strong", "b", "i", "code", "sup", "sub", "br", "a", "q", "small", "mark"]
    static let maxImages = 20
    static let maxImageBytes = 3_000_000

    public static func fetch(_ url: URL, transport: HTTPTransport = URLSessionTransport()) throws -> Article {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try transport.send(request)
        guard response.statusCode == 200 else { throw SendError.fetch(url, response.statusCode) }
        return try extract(html: data, from: url) { imageURL in
            var imageRequest = URLRequest(url: imageURL)
            imageRequest.setValue("InkRelay/\(InkRelayCore.version)", forHTTPHeaderField: "User-Agent")
            guard let (bytes, reply) = try? transport.send(imageRequest), reply.statusCode == 200 else { return nil }
            return bytes
        }
    }

    public static func extract(html: Data, from url: URL?, download: (URL) -> Data? = { _ in nil }) throws -> Article {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: markSections(html), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        } catch {
            throw SendError.unreadablePage
        }
        var title = first(document, [all("meta") + "[@property='og:title']/@content", all("title"), all("h1")])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? url?.host ?? "Article"
        // "Electronic paper - Wikipedia" → "Electronic paper".
        if let site = first(document, [all("meta") + "[@property='og:site_name']/@content"]) {
            for separator in [" - ", " | ", " \u{2014} ", " \u{2013} "] where title.hasSuffix(separator + site) {
                title = String(title.dropLast(separator.count + site.count))
            }
        }
        let byline = first(document, [all("meta") + "[@name='author']/@content", all("meta") + "[@property='article:author']/@content"])

        for name in dropped {
            for node in (try? document.nodes(forXPath: all(name) + " | //*[@data-ink-tag='\(name)']")) ?? [] { node.detach() }
        }
        let candidates = ((try? document.nodes(forXPath: ["div", "body"].map(all).joined(separator: " | "))) ?? [])
            .compactMap { $0 as? XMLElement }
        // An <article> or <main> that holds most of the text wins over the divs inside or around it.
        let marked = candidates.filter { ["article", "main"].contains(tag(of: $0)) || $0.attribute(forName: "role")?.stringValue == "main" }
        let best = candidates.max(by: { paragraphText($0) < paragraphText($1) })
        let content = marked.max(by: { paragraphText($0) < paragraphText($1) })
            .flatMap { article in paragraphText(article) * 2 >= (best.map(paragraphText) ?? 0) ? article : nil } ?? best
        guard let content else { throw SendError.unreadablePage }

        var images: [Article.EmbeddedImage] = []
        var xhtml = ""
        render(content, into: &xhtml, base: url, title: title, images: &images, download: download)
        xhtml = xhtml.replacingOccurrences(of: #"\s+</(p|li|h[1-6]|blockquote|figcaption|dt|dd)>"#, with: "</$1>", options: .regularExpression)
        xhtml = xhtml.replacingOccurrences(of: #"(<p>\s*</p>)+"#, with: "", options: .regularExpression)
        guard !xhtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SendError.unreadablePage }
        return Article(title: title, byline: byline, sourceURL: url, bodyXHTML: xhtml, images: images)
    }

    static let sectioning = ["article", "main", "nav", "header", "footer", "aside", "section", "figure", "figcaption", "template", "dialog", "menu", "picture", "source", "video", "audio"]

    /// The HTML parser predates HTML5 and drops its sectioning tags while keeping what's inside, which would
    /// let menus and footers into the article. Renaming them to marked divs first keeps their boundaries.
    static func markSections(_ html: Data) -> Data {
        var text = String(decoding: html, as: UTF8.self)
        for name in sectioning {
            text = text.replacingOccurrences(of: "<\(name)(?=[\\s>/])", with: "<div data-ink-tag=\"\(name)\"", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: "</\(name)\\s*>", with: "</div>", options: [.regularExpression, .caseInsensitive])
        }
        return Data(text.utf8)
    }

    /// The element's real tag, seeing through the divs `markSections` made.
    static func tag(of element: XMLElement) -> String {
        element.attribute(forName: "data-ink-tag")?.stringValue ?? (element.localName ?? element.name)?.lowercased() ?? ""
    }

    /// Paragraph text directly under `element`, so the wrapper around the whole page doesn't win just for being big.
    static func paragraphText(_ element: XMLElement) -> Int {
        // Walked by hand: a relative XPath (.//p) on an element can match the whole document.
        func paragraphs(in node: XMLNode) -> Int {
            guard let element = node as? XMLElement else { return 0 }
            if (element.localName ?? element.name)?.lowercased() == "p" { return element.stringValue?.count ?? 0 }
            return (element.children ?? []).reduce(0) { $0 + paragraphs(in: $1) }
        }
        let inside = paragraphs(in: element)
        let total = max(element.stringValue?.count ?? 1, 1)
        // Prefer dense blocks: most of the text should be paragraphs, not menus.
        return Int(Double(inside) * (Double(inside) / Double(total)))
    }

    /// Tidied HTML lives in the XHTML namespace, where a bare `//p` matches nothing; match on the local name.
    static func all(_ name: String) -> String {
        "//*[local-name()='\(name)']"
    }

    static func first(_ document: XMLDocument, _ queries: [String]) -> String? {
        for query in queries {
            if let value = (try? document.nodes(forXPath: query))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func render(_ node: XMLNode, into output: inout String, base: URL?, title: String, images: inout [Article.EmbeddedImage], download: (URL) -> Data?) {
        if node.kind == .text {
            output += escape(node.stringValue ?? "")
            return
        }
        guard let element = node as? XMLElement else { return }
        let name = tag(of: element)
        // The page title is the book title already.
        if name == "h1", element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == title { return }
        if name == "img" {
            guard images.count < maxImages,
                  let source = element.attribute(forName: "src")?.stringValue,
                  let absolute = URL(string: source, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(absolute.scheme ?? ""),
                  let data = download(absolute), data.count <= maxImageBytes,
                  let (ext, type) = imageType(data) else { return }
            let file = "image\(images.count + 1).\(ext)"
            images.append(Article.EmbeddedImage(name: file, mediaType: type, data: data))
            let alt = escape(element.attribute(forName: "alt")?.stringValue ?? "")
            output += "<img src=\"images/\(file)\" alt=\"\(alt)\"/>"
            return
        }
        func children() {
            for child in element.children ?? [] { render(child, into: &output, base: base, title: title, images: &images, download: download) }
        }
        if name == "br" || name == "hr" {
            output += "<\(name)/>"
        } else if blocks.contains(name) || inline.contains(name) {
            if name == "a", let href = element.attribute(forName: "href")?.stringValue,
               let link = URL(string: href, relativeTo: base)?.absoluteURL, ["http", "https"].contains(link.scheme ?? "") {
                output += "<a href=\"\(escape(link.absoluteString))\">"
                children()
                output += "</a>"
            } else if name == "a" {
                children()
            } else {
                output += "<\(name)>"
                children()
                output += "</\(name)>"
                if blocks.contains(name) { output += "\n" }
            }
        } else {
            children()
        }
    }

    /// EPUB readers take JPEG, PNG and GIF; anything else is left out.
    static func imageType(_ data: Data) -> (String, String)? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xD8]) { return ("jpg", "image/jpeg") }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return ("gif", "image/gif") }
        return nil
    }

    static func escape(_ text: String) -> String { XHTML.escape(text) }
}
#endif

/// Escaping for text and attribute values in XHTML.
enum XHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Packs an article as an EPUB 3 book, which every e-ink tablet reads and reflows to its screen.
public enum EPUBWriter {
    public static func book(_ article: Article, savedAt: Date = Date()) -> Data {
        let identifier = "urn:uuid:" + UUID().uuidString
        let modified = ISO8601DateFormatter().string(from: savedAt).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let title = XHTML.escape(article.title)
        let author = XHTML.escape(article.byline ?? article.sourceURL?.host ?? "InkRelay")
        let saved = DateFormatter.localizedString(from: savedAt, dateStyle: .medium, timeStyle: .none)
        let source = article.sourceURL.map { "<p class=\"source\">Saved from <a href=\"\(XHTML.escape($0.absoluteString))\">\(XHTML.escape($0.host ?? $0.absoluteString))</a> on \(saved).</p>" } ?? ""

        let chapter = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
        <head><meta charset="utf-8"/><title>\(title)</title><link rel="stylesheet" href="style.css"/></head>
        <body><h1>\(title)</h1>\(article.byline.map { "<p class=\"byline\">\(XHTML.escape($0))</p>" } ?? "")\(source)
        \(article.bodyXHTML)
        </body></html>
        """
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(title)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="article.xhtml">\(title)</a></li></ol></nav></body></html>
        """
        let manifestImages = article.images.map { "<item id=\"\($0.name.replacingOccurrences(of: ".", with: "-"))\" href=\"images/\($0.name)\" media-type=\"\($0.mediaType)\"/>" }.joined(separator: "\n    ")
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">\(identifier)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="article" href="article.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifestImages)
          </manifest>
          <spine><itemref idref="article"/></spine>
        </package>
        """
        let container = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let css = "body{font-family:serif;line-height:1.5;margin:0 4%}h1{font-size:1.6em;line-height:1.2}.byline,.source{color:#555;font-size:.9em}img{max-width:100%;height:auto}blockquote{margin-left:1em;padding-left:.8em;border-left:2px solid #999}pre{white-space:pre-wrap}"

        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data(container.utf8))
        zip.add("OEBPS/content.opf", Data(opf.utf8))
        zip.add("OEBPS/nav.xhtml", Data(nav.utf8))
        zip.add("OEBPS/article.xhtml", Data(chapter.utf8))
        zip.add("OEBPS/style.css", Data(css.utf8))
        for image in article.images { zip.add("OEBPS/images/\(image.name)", image.data) }
        return zip.finish()
    }
}

public enum SendError: Error, LocalizedError, Equatable {
    case fetch(URL, Int)
    case unreadablePage
    case unsupportedFile(String)
    case noTarget(String)

    public var errorDescription: String? {
        switch self {
        case .fetch(let url, let status): return "Couldn't fetch \(url.absoluteString) (HTTP \(status))."
        case .unreadablePage: return "Couldn't find an article on that page."
        case .unsupportedFile(let ext): return "Can't send .\(ext) files; send a web link, PDF, EPUB, HTML, Markdown or text file."
        case .noTarget(let reason): return reason
        }
    }
}
