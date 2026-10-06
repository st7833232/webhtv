/**
 * csp_HaokanDJ — ported from `com.github.catvod.spider.HaokanDJ` (xiaosa-0807.jar, 158 lines).
 *
 * Baidu 好看视频's playlet shelf. No crypto: every call is a form POST to `sv.baidu.com` with the app's
 * UA and a fixed `BAIDUCUID` cookie. The detail is two hops (`video/commonlist` gives the playlet's
 * first `vid`, `rec/detail` gives every episode's), and the player asks `video/relate` for the
 * episode's quality list, taking 1080p, then `sc`, then whatever comes first.
 *
 * IOS-POC-44B. Measured 2026-10-02: tags, a category, a 70-episode detail and the 1080p mp4 (206)
 * answered; **search returns nothing** (`猜空了`) with the original's parameters, which is reproduced
 * here as an empty result rather than guessed around.
 */
var spider = (function () {
  'use strict';

  var API = 'https://sv.baidu.com/';
  var UA = 'Mozilla/5.0 (Linux; Android 11; M2012K10C Build/RP1A.200720.011; wv) AppleWebKit/537.36 '
    + '(KHTML, like Gecko) Version/4.0 Chrome/87.0.4280.141 Mobile Safari/537.36 haokan/7.80.0.18 '
    + '(Baidu; P1 11)/imoaiX_03_11_C01K2102M/1043677m/5ACDB023CFB9D64743B08E51953F7C76%7CVSAJ32AVA/1/'
    + '7.80.0.18/780001/1/immersiveMode/modeV4PlusWhite/isFirstInstall/bbqMode/bbqModeV2/blackStyle/'
    + 'isPlaylet Talos/1.8.7';
  var PAGE = 9;

  /** `b.g(url, form, a())`: a form POST with the app's headers. */
  function post(path, form) {
    return host.post(API + path, form, {
      headers: { 'User-Agent': UA, 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
                 'Cookie': 'BAIDUCUID=giHCu0azv80G8SfQ0avU8gaaH8jfiv86ju2MugiR2i8-k3a35avAa1_mA',
                 'Talos-Module-Version': '1.0.71.1', 'Talos-Module-Name': 'shortDrama' },
      timeout: 20000
    }).json || {};
  }

  /** `extractVideoUrl`: 1080p, then `sc`, then the first entry. */
  function bestQuality(list) {
    list = list || [];
    var pick = function (key) {
      var hit = list.filter(function (q) { return q.key === key; })[0];
      return hit ? hit.url : '';
    };
    return pick('1080p') || pick('sc') || (list[0] || {}).url || '';
  }

  return {
    init: function () { return ''; },

    homeContent: function () {
      var panels = (post('haokan/ui-feed/playletShelfFeed?osbranch=a0', { from: 'feed' }).data || {})
        .playlet_shelf_filter_panel || [];
      var classes = [];
      panels.forEach(function (panel) {
        (panel.tag_list || []).forEach(function (t) { classes.push({ type_id: t.tag_id, type_name: t.name }); });
      });
      return host.result.home(classes);
    },

    categoryContent: function (tid, page, filter, extend) {
      var tag = (extend && extend.cateId) || tid;
      var data = post('haokan/ui-feed/playletTagsFeed?osbranch=a0', { tag_id: tag, rn: String(PAGE), pn: String(page || '1') }).data || {};
      var items = (data.list || []).map(function (v) {
        return { vod_id: v.playlet_id, vod_name: v.playlet_title, vod_pic: v.playlet_poster, vod_remarks: v.episodes_num_text };
      });
      // The original pages without an end (`Integer.MAX_VALUE` items); a short page is the honest end.
      var pg = parseInt(page, 10) || 1;
      return host.result.page(items, pg, items.length < PAGE ? pg : pg + 1, PAGE);
    },

    detailContent: function (ids) {
      var id = String(ids[0]);
      // `%S` upper-cases its argument; the timestamp and the numeric id are unchanged by that.
      var list = post('appui/api?osbranch=a0', { 'video/commonlist':
        'enable_enter_playlet=0&seek_time=0&hotspot=0&auto_show_hot_point_panel=0&type=playlet&commonlist_id='
        + host.now() + '&scene=&vid=&enable_atlas=0&mark_pn=&uk=&ctime=0&from=playlet_new&id=' + id.toUpperCase()
        + '&rn=10&pn=1&direction=3' });
      var first = (((((list['video/commonlist'] || {}).data || {}).results || [])[0] || {}).content || {}).vid;
      var data = first ? (post('haokan/ui-video/playlet/rec/detail?osbranch=a0', { vid: first, playlet_id: id }).data || {}) : {};
      var episodes = (data.vid_list || []).map(function (vid, i) { return '第' + (i + 1) + '集$' + vid + '|||' + id; });
      return host.result.detail({
        vod_id: id,
        vod_name: data.playlet_title || '',
        vod_pic: data.playlet_poster || '',
        vod_content: data.description || '',
        vod_play_from: episodes.length ? '短剧' : '',
        vod_play_url: episodes.join('#')
      });
    },

    searchContent: function (key) {
      var data = post('haokan/ui-interact/playlet/search/sugs?osbranch=a0', { search_word: String(key || '') }).data;
      return host.result.list((Array.isArray(data) ? data : []).map(function (v) {
        return { vod_id: v.id, vod_name: v.title, vod_pic: v.cover_url, vod_remarks: v.tag };
      }));
    },

    /** The id is `vid|||playletId`. */
    playerContent: function (flag, id) {
      var parts = String(id).split('|||');
      var relate = post('appui/api?osbranch=a0', { 'video/relate':
        'method=post&vid=' + parts[0] + '&immersive_mode=v4_5&tplname=feed_small_video&tag=playlet_talos&tab=detail'
        + '&external_from=&is_dp_video=0&immersive_square_type=3&video_set_id=' + (parts[1] || '')
        + '&play_screen_type=1&play_volume_type=2&play_external_device_type=1' });
      var video = (((relate['video/relate'] || {}).data || {}).cur_video || {});
      return host.result.play(bestQuality(video.clarityUrl), false, { 'User-Agent': UA });
    },

    isVideoFormat: host.isVideoFormat,
    manualVideoCheck: function () { return false; },
    destroy: function () {}
  };
})();

module.exports = spider;
