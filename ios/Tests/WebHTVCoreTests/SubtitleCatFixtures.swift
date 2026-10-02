import Foundation

/// IOS-POC-45 — Subtitle Cat pages and subtitle files, cut down to what the parser reads.
///
/// **Reconstructed, not captured.** The cloud session that wrote these could not reach
/// subtitlecat.com (the egress proxy refused the host), so the markup follows the site's layout as
/// known before that — a results table linking `subs/<number>/<name>.html`, and result pages with
/// one block per language holding either a direct `…-<code>.srt` link or a Translate button — and
/// deliberately varies it (relative and absolute links, quoting, entities, a table layout, stray
/// tags) so the tests pin the tolerant reading rather than one exact page. Replace them with real
/// captures, trimmed, once the site can be reached; no fixture holds a cookie, token or account.
enum SubtitleCatFixture {
    static let searchPage = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Subtitle Cat - Search: FC2-PPV-4159457</title>
      <script>var trap = '<a href="subs/1/not-a-result.html">x</a>';</script>
    </head>
    <body>
    <nav class="navbar"><a href="index.html">Subtitle Cat</a> <a href="upload.php">Upload</a> <a href="/subs/">Browse</a></nav>
    <div class="container">
      <form action="index.php" method="get"><input type="text" name="search" value="FC2-PPV-4159457"><button>Search</button></form>
      <table class="table sub-table">
        <thead><tr><th>Subtitle</th><th>Rating</th><th>Downloads</th><th>Languages</th></tr></thead>
        <tbody>
          <tr><td><a href="subs/1234/FC2-PPV-4159457.html">FC2-PPV-4159457</a> (translated from Japanese)</td><td></td><td>327 downloads</td><td>12 languages</td></tr>
          <tr><td><A HREF='/subs/998/FC2PPV-4159457-part2.html'>FC2PPV 4159457 &amp; part 2</A></td><td></td><td>12 downloads</td><td>4 languages</td>
          <tr><td><a href=https://www.subtitlecat.com/subs/77/fc2-ppv-4159457-alt.html>fc2-ppv-4159457 alt</a></td><td></td><td>3 downloads</td><td>2 languages</td></tr>
          <tr><td><a href="subs/1234/FC2-PPV-4159457.html">FC2-PPV-4159457</a></td><td>duplicate row</td></tr>
          <tr><td><a href="https://elsewhere.example/subs/5/FC2-PPV-4159457.html">mirror</a></td></tr>
        </tbody>
      </table>
    </div>
    <footer><a href="dmca.php">DMCA</a></footer>
    </body>
    </html>
    """#

    static let noResultsPage = #"""
    <!DOCTYPE html>
    <html><head><title>Subtitle Cat - Search: zzzzzzzz</title></head>
    <body>
    <nav><a href="index.html">Subtitle Cat</a></nav>
    <form action="index.php" method="get"><input name="search" value="zzzzzzzz"></form>
    <table class="table sub-table"><thead><tr><th>Subtitle</th></tr></thead><tbody></tbody></table>
    <p>No subtitles found.</p>
    </body></html>
    """#

    /// A result page: direct files for zh-TW, zh-CN, ja, en and ko; French and German offered only
    /// to translate — German through a link that even points at an `.srt`.
    static let detailPage = #"""
    <!DOCTYPE html>
    <html><head><title>FC2-PPV-4159457 subtitles</title></head>
    <body>
    <div class="container">
      <h1>FC2-PPV-4159457</h1>
      <p>Original language: Japanese. Download a ready subtitle, or translate it.</p>
      <div class="all-sub">
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/kr.png" alt="ko"></span><span>&nbsp;Korean</span>
          <span><a id="download_ko" href="/subs/1234/FC2-PPV-4159457-ko.srt" class="green-link">Download</a></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/jp.png" alt="ja"></span><span>&nbsp;Japanese</span>
          <span><a id="download_ja" href="FC2-PPV-4159457-ja.srt" class="green-link">Download</a></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/us.png" alt="en"></span><span>&nbsp;English</span>
          <span><a id="download_en" href="http://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-en.srt" class="green-link">Download</a></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/fr.png" alt="fr"></span><span>&nbsp;French</span>
          <span><button class="yellow-link" id="trans_fr" onclick="translate_from_server_folder('fr', 'FC2-PPV-4159457.srt', '/subs/1234/')">Translate</button></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/cn.png" alt="zh-CN"></span><span>&nbsp;Chinese (Simplified)</span>
          <span><a id="download_zh-CN" href="/subs/1234/FC2-PPV-4159457-zh-CN.srt" class="green-link">Download</a></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/de.png" alt="de"></span><span>&nbsp;German</span>
          <span><a class="yellow-link" href="/subs/1234/FC2-PPV-4159457-de.srt" onclick="translate_from_server_folder('de', 'FC2-PPV-4159457.srt', '/subs/1234/'); return false;">Translate</a></span></div>
        <div class="sub-single"><span><img src="https://flagcdn.com/16x12/tw.png" alt="zh-TW"></span><span>&nbsp;Chinese (<b>Traditional</b>)</span>
          <span><a id="download_zh-TW" href="/subs/1234/FC2-PPV-4159457-zh-TW.srt" class="green-link">Download</a></span></div>
        <div class="sub-single"><span>Spam</span><span><a href="https://elsewhere.example/FC2-PPV-4159457-zh-TW.srt">Download</a></span></div>
      </div>
      <script>document.write('<a href="/subs/1234/script-only-zh-TW.srt">x</a>')</script>
    </div>
    </body></html>
    """#

    /// A table-shaped result page whose labels disagree with the file names: the label wins; a
    /// link with no label anywhere falls back to its file name.
    static let tableDetailPage = #"""
    <html><body>
    <table>
      <tr><td>Chinese (Traditional)</td><td><a href="/subs/55/Movie.2020-zh-CN.srt">Download</a></td>
      <tr><td>English</td><td><a href="/subs/55/Movie.2020.srt">Download</a></td></tr>
    </table>
    <div><a href="/subs/55/Movie.2020-ja.srt"></a></div>
    </body></html>
    """#

    /// Every language only translatable: a readable page with no file.
    static let translateOnlyPage = #"""
    <html><body><div class="sub-single"><span>Chinese (Traditional)</span>
    <button onclick="translate_from_server_folder('zh-TW', 'X.srt', '/subs/9/')">Translate</button></div></body></html>
    """#

    static let cloudflareChallenge = #"""
    <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
    <meta http-equiv="refresh" content="390"></head>
    <body><div id="challenge-running">Checking your browser before accessing www.subtitlecat.com.</div>
    <script>window._cf_chl_opt={cvId:'3',cZone:"www.subtitlecat.com"};</script>
    <script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script></body></html>
    """#

    static let htmlErrorPage = #"""
    <!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1>
    <p>The requested URL was not found on this server.</p></body></html>
    """#

    static let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    你好，這是第一句。

    2
    00:00:04,000 --> 00:00:06,000
    <i>第二句</i>
    第二行

    """

    /// Windows line endings, no counter lines, a dot before the milliseconds.
    static let srtCRLFNoCounters = "00:00:01.000 --> 00:00:02.000\r\nOne\r\n\r\n00:00:02.500 --> 00:00:04.000\r\nTwo\r\n"
}
