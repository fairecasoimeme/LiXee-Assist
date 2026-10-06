/// Navigation aux flèches dans l'interface web de la box, sur TV.
///
/// Script injecté à chaque chargement de page. Il expose `window.__lxNav`,
/// que l'écran Flutter appelle à chaque touche :
///
/// - `move('up'|'down'|'left'|'right')` sélectionne l'élément cliquable le
///   plus proche dans cette direction, et fait défiler la page quand il n'y
///   en a plus ;
/// - `activate()` clique l'élément sélectionné, ou y place le curseur de
///   saisie pour un champ — seul cas où le clavier de la TV s'ouvre.
///
/// Le choix de l'élément suit la règle des lanceurs TV : on retient ce qui est
/// franchement dans la direction demandée, et parmi eux le plus proche, en
/// pénalisant le décalage de côté pour ne pas sauter d'une colonne à l'autre.
const tvWebNavigationScript = r'''
(function () {
  if (window.__lxNav) { window.__lxNav.refresh(); return; }

  var style = document.createElement('style');
  style.textContent =
    '.lx-focus{outline:4px solid #4fa8ff !important;outline-offset:2px !important;' +
    'box-shadow:0 0 0 8px rgba(79,168,255,.28) !important;border-radius:4px}';
  (document.head || document.documentElement).appendChild(style);

  var SELECTOR = 'a[href],button,input:not([type=hidden]),select,textarea,' +
    '[onclick],[role=button],[role=tab],[role=menuitem],[tabindex]:not([tabindex="-1"]),summary';
  var current = null;

  function visible(el) {
    if (el.disabled) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    var s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
  }

  function candidates() {
    var list = Array.prototype.slice.call(document.querySelectorAll(SELECTOR));
    return list.filter(function (el) {
      if (!visible(el)) return false;
      // Un élément cliquable qui en contient d'autres (carte à onclick
      // garnie de boutons, lien autour d'un bouton) cède la place à ceux-ci :
      // un clic sur l'intérieur remonte de toute façon jusqu'à lui.
      var inner = el.querySelectorAll(SELECTOR);
      for (var i = 0; i < inner.length; i++) { if (visible(inner[i])) return false; }
      return true;
    });
  }

  function select(el) {
    if (current) current.classList.remove('lx-focus');
    current = el;
    if (!el) return;
    el.classList.add('lx-focus');
    var r = el.getBoundingClientRect();
    var margin = 80;
    if (r.top < margin || r.bottom > innerHeight - margin ||
        r.left < 0 || r.right > innerWidth) {
      el.scrollIntoView({ block: 'center', inline: 'nearest' });
    }
  }

  function center(r) { return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }

  function move(dir) {
    var list = candidates();
    if (!list.length) { scroll(dir); return 'scroll'; }
    if (!current || !document.contains(current) || !visible(current)) {
      // Premier appui : l'élément le plus haut à gauche encore à l'écran.
      var onScreen = list.filter(function (el) {
        var r = el.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight;
      });
      var pool = onScreen.length ? onScreen : list;
      pool.sort(function (a, b) {
        var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
        return (ra.top - rb.top) || (ra.left - rb.left);
      });
      select(pool[0]);
      return 'first';
    }
    var from = current.getBoundingClientRect(), c = center(from);
    var best = null, bestScore = Infinity;
    list.forEach(function (el) {
      if (el === current) return;
      var r = el.getBoundingClientRect(), p = center(r), main, side;
      if (dir === 'down') { if (r.top < from.bottom - 2) return; main = r.top - from.bottom; side = Math.abs(p.x - c.x); }
      else if (dir === 'up') { if (r.bottom > from.top + 2) return; main = from.top - r.bottom; side = Math.abs(p.x - c.x); }
      else if (dir === 'right') { if (r.left < from.right - 2) return; main = r.left - from.right; side = Math.abs(p.y - c.y); }
      else { if (r.right > from.left + 2) return; main = from.left - r.right; side = Math.abs(p.y - c.y); }
      var score = Math.max(main, 0) + side * 2.5;
      if (score < bestScore) { bestScore = score; best = el; }
    });
    if (best) { select(best); return 'moved'; }
    scroll(dir);
    return 'scroll';
  }

  function scroll(dir) {
    var dy = dir === 'down' ? 0.6 : dir === 'up' ? -0.6 : 0;
    var dx = dir === 'right' ? 0.6 : dir === 'left' ? -0.6 : 0;
    window.scrollBy({ top: dy * innerHeight, left: dx * innerWidth, behavior: 'smooth' });
  }

  function activate() {
    var el = current;
    if (!el || !document.contains(el)) return 'none';
    var tag = el.tagName, type = (el.getAttribute('type') || '').toLowerCase();
    var typing = tag === 'TEXTAREA' || (tag === 'INPUT' &&
      ['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file'].indexOf(type) < 0);
    if (typing) { el.focus(); return 'input'; }
    if (tag === 'SELECT') { el.focus(); el.click(); return 'select'; }
    el.click();
    return 'click';
  }

  function refresh() {
    if (current && !document.contains(current)) current = null;
  }

  window.__lxNav = { move: move, activate: activate, refresh: refresh,
    clear: function () { select(null); } };
})();
''';
