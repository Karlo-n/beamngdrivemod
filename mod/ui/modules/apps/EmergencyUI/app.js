angular.module('beamng.apps')
.directive('emergencyui', ['bngApi', function (bngApi) {
  return {
    replace: true,
    restrict: 'EA',
    template: [
      '<div class="tai-duty">',
      '  <style>',
      '  .tai-duty{position:absolute;inset:0;display:flex;flex-direction:column;',
      '    font-family:"Overpass Mono","Roboto Mono",monospace;font-size:11px;color:#c9d2d9;',
      '    background:linear-gradient(180deg,#12161a 0%,#0c0f12 100%);',
      '    border:1px solid #262e35;border-radius:3px;overflow:hidden;',
      '    box-shadow:inset 0 1px 0 rgba(255,255,255,.04)}',
      '  .tai-off{flex:1;display:flex;align-items:center;justify-content:center;',
      '    color:#4b565f;letter-spacing:.14em;font-size:10px;text-align:center;padding:0 18px;',
      '    line-height:1.8}',
      '  .tai-hd{display:flex;align-items:center;gap:8px;padding:7px 9px;',
      '    background:#161c22;border-bottom:1px solid #262e35}',
      '  .tai-bar{width:3px;height:24px;border-radius:1px;background:#3d7fd6}',
      '  .tai-bar.medic{background:#37b57a}.tai-bar.fire{background:#d1553b}',
      '  .tai-bar.swat{background:#8a6bd1}.tai-bar.undercover{background:#8894a0}',
      '  .tai-cs{font-size:13px;font-weight:600;color:#e8eef3;letter-spacing:.06em}',
      '  .tai-sub{font-size:9px;color:#6b7883;letter-spacing:.12em;text-transform:uppercase}',
      '  .tai-st{margin-left:auto;text-align:right}',
      '  .tai-dot{display:inline-block;width:6px;height:6px;border-radius:50%;',
      '    background:#37b57a;margin-right:5px;vertical-align:middle}',
      '  .tai-dot.busy{background:#e0a33c}',
      '  .tai-covert{padding:3px 9px;background:#171a1d;border-bottom:1px solid #23282d;',
      '    color:#8894a0;font-size:9px;letter-spacing:.12em}',
      '  .tai-wanted{padding:4px 9px;background:#2a1416;border-bottom:1px solid #402024;',
      '    color:#e8756a;letter-spacing:.1em;font-size:10px}',
      '  .tai-tg{padding:8px 9px;border-bottom:1px solid #1d242a;background:#0f1418}',
      '  .tai-tg-none{color:#4b565f;font-style:italic}',
      '  .tai-nm{color:#e8eef3;font-size:12px;margin-bottom:5px;white-space:nowrap;',
      '    overflow:hidden;text-overflow:ellipsis}',
      '  .tai-row{display:flex;gap:10px;margin-bottom:3px}',
      '  .tai-k{color:#6b7883;min-width:62px}',
      '  .tai-v{color:#c9d2d9}.tai-v.hot{color:#e8756a}',
      '  .tai-tags{margin-top:5px;display:flex;flex-wrap:wrap;gap:4px}',
      '  .tai-tag{background:#3a1f22;color:#e08a7f;border:1px solid #552d31;',
      '    padding:1px 5px;border-radius:2px;font-size:9px;letter-spacing:.06em}',
      '  .tai-tag.ok{background:#1a2a22;color:#6fbf95;border-color:#27412f}',
      '  .tai-acts{padding:7px;display:grid;grid-template-columns:1fr 1fr;gap:5px}',
      '  .tai-b{appearance:none;border:1px solid #2c353d;background:#1a2127;color:#c9d2d9;',
      '    padding:7px 6px;border-radius:2px;font:inherit;font-size:10px;cursor:pointer;',
      '    letter-spacing:.05em;text-align:left;transition:background .12s,border-color .12s}',
      '  .tai-b:hover:not(:disabled){background:#232c34;border-color:#3d4a55}',
      '  .tai-b:active:not(:disabled){background:#151b20}',
      '  .tai-b:disabled{opacity:.32;cursor:default}',
      '  .tai-b.wide{grid-column:1 / -1}',
      '  .tai-b.warn{border-color:#5a2d27;color:#e08a7f}',
      '  .tai-b.warn:hover:not(:disabled){background:#2a1a18}',
      '  .tai-log{flex:1;overflow-y:auto;padding:6px 9px;border-top:1px solid #1d242a;',
      '    background:#0a0d10;line-height:1.55}',
      '  .tai-le{color:#8894a0;padding:1px 0}',
      '  .tai-le:first-child{color:#c9d2d9}',
      '  .tai-log::-webkit-scrollbar{width:5px}',
      '  .tai-log::-webkit-scrollbar-thumb{background:#242c33;border-radius:3px}',
      '  .tai-ft{padding:5px 9px;background:#0f1418;border-top:1px solid #1d242a;',
      '    display:flex;justify-content:space-between;color:#6b7883;font-size:9px;',
      '    letter-spacing:.08em}',
      '  </style>',

      '  <div class="tai-off" ng-if="d.role===\'none\'">',
      '    FUERA DE SERVICIO<br><br>Conduce una patrulla, ambulancia,<br>',
      '    bomba, blindado o coche camuflado.',
      '  </div>',

      '  <div ng-if="d.role!==\'none\'" style="display:flex;flex-direction:column;height:100%">',
      '    <div class="tai-hd">',
      '      <div class="tai-bar" ng-class="d.role"></div>',
      '      <div>',
      '        <div class="tai-cs">{{d.callsign}}</div>',
      '        <div class="tai-sub">{{roleName()}}</div>',
      '      </div>',
      '      <div class="tai-st">',
      '        <div><span class="tai-dot" ng-class="{busy: d.status!==\'available\'}"></span>',
      '          <span class="tai-sub">{{d.status}}</span></div>',
      '      </div>',
      '    </div>',

      '    <div class="tai-covert" ng-if="d.role===\'undercover\'">SIN DISTINTIVOS &mdash; NO IDENTIFICADO</div>',
      '    <div class="tai-wanted" ng-if="d.stars>0">BUSQUEDA ACTIVA &mdash; NIVEL {{d.stars}}</div>',

      '    <div class="tai-tg">',
      '      <div class="tai-tg-none" ng-if="!d.target">Sin objetivo marcado</div>',
      '      <div ng-if="d.target">',
      '        <div class="tai-nm">{{d.target.name}}</div>',
      '        <div class="tai-row"><span class="tai-k">Velocidad</span>',
      '          <span class="tai-v" ng-class="{hot: d.target.speed > d.target.limit}">',
      '          {{d.target.speed}} / {{d.target.limit}} km/h</span></div>',
      '        <div class="tai-row"><span class="tai-k">Danos</span>',
      '          <span class="tai-v" ng-class="{hot: d.target.damage>3000}">{{d.target.damage}}</span></div>',
      '        <div class="tai-row" ng-if="d.target.searched"><span class="tai-k">Registro</span>',
      '          <span class="tai-v">{{d.target.searched}}</span></div>',
      '        <div class="tai-tags">',
      '          <span class="tai-tag" ng-if="d.target.wanted">RECLAMADO</span>',
      '          <span class="tai-tag" ng-repeat="o in d.target.offenses">{{o}}</span>',
      '          <span class="tai-tag ok" ng-if="!d.target.wanted && !d.target.offenses.length">',
      '            sin antecedentes</span>',
      '        </div>',
      '      </div>',
      '    </div>',

      '    <div class="tai-acts">',
      '      <button class="tai-b wide" ng-click="act(\'selectNearest\')">MARCAR MAS CERCANO</button>',
      '      <button class="tai-b" ng-repeat="b in buttons()"',
      '        ng-class="{wide: b.w, warn: b.r}"',
      '        ng-disabled="b.need==\'t\' && !d.target || b.need==\'s\' && (!d.target || !d.target.stopped)"',
      '        ng-click="act(b.f)">{{b.t}}</button>',
      '    </div>',

      '    <div class="tai-log">',
      '      <div class="tai-le" ng-repeat="l in d.log track by $index">{{l}}</div>',
      '    </div>',

      '    <div class="tai-ft">',
      '      <span>MULTAS {{d.fineCount}}</span><span>TOTAL {{d.fines}}</span>',
      '    </div>',
      '  </div>',
      '</div>'
    ].join(''),

    link: function (scope) {
      scope.d = {role: 'none', callsign: '', status: 'available', stars: 0,
                 fines: 0, fineCount: 0, log: [], target: null};

      var NAMES = {police: 'Policia', medic: 'Servicio medico', fire: 'Bomberos',
                   swat: 'Unidad blindada', undercover: 'Unidad camuflada'};

      // need: 't' = necesita objetivo, 's' = objetivo detenido. w = ancho, r = accion seria.
      var SETS = {
        police: [
          {t: 'CONSULTAR MATRICULA', f: 'runPlate', need: 't'},
          {t: 'DAR EL ALTO', f: 'signalStop', need: 't'},
          {t: 'REGISTRAR MALETERO', f: 'searchVehicle', need: 's'},
          {t: 'ALCOHOLEMIA', f: 'breathTest', need: 's'},
          {t: 'EMITIR MULTA', f: 'issueTicket', need: 't'},
          {t: 'PEDIR APOYO', f: 'callBackup'},
          {t: 'PREPARAR PINCHOS', f: 'deploySpikes'},
          {t: 'DEJAR SEGUIR', f: 'releaseStop'},
          {t: 'DETENER', f: 'arrest', need: 's', r: true, w: true}
        ],
        swat: [
          {t: 'CONSULTAR MATRICULA', f: 'runPlate', need: 't'},
          {t: 'MONTAR CONTROL', f: 'roadblock'},
          {t: 'ESTABLECER PERIMETRO', f: 'perimeter'},
          {t: 'PEDIR APOYO', f: 'callBackup'},
          {t: 'PREPARAR PINCHOS', f: 'deploySpikes'},
          {t: 'DAR EL ALTO', f: 'signalStop', need: 't'},
          {t: 'DETENER', f: 'arrest', need: 's', r: true, w: true}
        ],
        undercover: [
          {t: 'CONSULTAR MATRICULA', f: 'runPlate', need: 't'},
          {t: 'SEGUIR SIN IDENTIFICARSE', f: 'tail', need: 't', w: true},
          {t: 'PEDIR UNIDADES', f: 'callBackup'},
          {t: 'REGISTRAR MALETERO', f: 'searchVehicle', need: 's'},
          {t: 'IDENTIFICARSE', f: 'blowCover', r: true, w: true},
          {t: 'DETENER', f: 'arrest', need: 's', r: true, w: true}
        ],
        medic: [
          {t: 'ATENDER HERIDOS', f: 'treat', need: 't', w: true},
          {t: 'TRASLADAR', f: 'transport', need: 't'},
          {t: 'PEDIR BOMBEROS', f: 'requestFire'},
          {t: 'ASEGURAR LA ESCENA', f: 'secureScene', w: true}
        ],
        fire: [
          {t: 'SOFOCAR INCENDIO', f: 'extinguish', need: 't', w: true},
          {t: 'PEDIR SANITARIOS', f: 'requestMedic'},
          {t: 'PEDIR APOYO', f: 'callBackup'},
          {t: 'ASEGURAR LA ESCENA', f: 'secureScene', w: true}
        ]
      };

      scope.roleName = function () { return NAMES[scope.d.role] || ''; };
      scope.buttons = function () { return SETS[scope.d.role] || []; };
      scope.act = function (fn) { bngApi.engineLua('trafficAI_duty.' + fn + '()'); };

      scope.$on('TrafficAIDuty', function (ev, data) {
        if (!data) { return; }
        scope.$evalAsync(function () { scope.d = data; });
      });

      bngApi.engineLua('trafficAI_duty.push()');
    }
  };
}]);
