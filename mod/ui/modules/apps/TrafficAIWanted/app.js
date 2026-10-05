angular.module('beamng.apps')
.directive('trafficaiwanted', [function () {
  return {
    template:
      '<div id="taiw-root" style="width:100%;height:100%;display:flex;align-items:center;' +
      'justify-content:center;font-family:\'Overpass Mono\',monospace;pointer-events:none;' +
      'opacity:0;transition:opacity .45s ease">' +
      '<span id="taiw-stars" style="font-size:34px;letter-spacing:3px;' +
      'text-shadow:0 0 7px rgba(0,0,0,.95),0 2px 3px rgba(0,0,0,.9);' +
      'transition:color .4s ease,transform .3s ease;display:inline-block"></span>' +
      '</div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element) {
      var root = element[0];
      var box = root.querySelector('#taiw-stars');
      var last = -1;

      function glyphs(n) {
        var s = '';
        for (var i = 1; i <= 5; i++) {
          if (n >= i) { s += '\u2605'; }
          else if (n >= i - 0.5) { s += '\u25D0'; }
          else { s += '\u2606'; }
        }
        return s;
      }

      function render(n, rising) {
        if (n === last) { return; }
        var wasZero = last <= 0;
        last = n;
        box.textContent = glyphs(n);
        box.style.color = n >= 4 ? '#ff4444' : (n >= 2.5 ? '#ff8833' : '#ffcc33');
        root.style.opacity = n > 0 ? '1' : '0';
        if (n > 0) {
          box.style.transform = rising ? 'scale(1.35)' : 'scale(0.85)';
          setTimeout(function () { box.style.transform = 'scale(1)'; }, wasZero ? 260 : 200);
        }
      }
      render(0, false);

      scope.$on('TrafficAIWanted', function (ev, data) {
        render((data && data.stars) || 0, data && data.rising);
      });
      scope.$on('$destroy', function () { last = -1; });
    }
  };
}]);
