# Estructura del proyecto — TrafficAI (BeamNG.drive 0.39.4)

Documento de referencia de la estructura de carpetas. **En disco solo existen carpetas.**
Los archivos que aparecen en el árbol de abajo están *planificados*, no creados todavía; se
listan para que se vea qué va en cada sitio.

La validación de esta estructura contra otros sistemas de IA de tráfico está en
[REFERENCIAS-ARQUITECTURA.md](REFERENCIAS-ARQUITECTURA.md).

---

## 1. Verificación de la versión

| Dato | Valor |
|---|---|
| Versión instalada | `v0.39.4.0` |
| Build | `buildbot build 20972 on winbuildbot - 07/08/2026` |
| Ruta del juego | `C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive` |
| Carpeta de usuario | `C:\Users\yolor\AppData\Local\BeamNG\BeamNG.drive\current` |

La versión se confirmó leyendo `integrity.json` en la raíz del juego y la carpeta
`v0.39.4.0__backup_cloud_sync` de la carpeta de usuario.

La estructura de abajo no está inventada: se copió de tres mods de código reales ya
instalados en esta máquina (`fluidspill-100.zip`, `animated_wipers.zip`,
`dynamic_damage_particles.zip`), que comparten exactamente el mismo esqueleto.

---

## 2. Árbol del proyecto

```text
BeamNG drive AI traffic new/
│
├── docs/                  ← documentación (NO se empaqueta en el mod)
│   ├── ESTRUCTURA.md
│   └── REFERENCIAS-ARQUITECTURA.md
│
└── mod/                   ← ESTO es el mod. Su contenido es la raíz del .zip
    │
    ├── scripts/
    │   └── trafficAI/
    │       └── modScript.lua
    │
    ├── lua/
    │   ├── ge/extensions/
    │   │   ├── core/input/actions/
    │   │   │   └── trafficAI.json
    │   │   ├── gameplay/traffic/roles/
    │   │   │   └── trafficAI.lua        ← ruta OBLIGATORIA (ver §4)
    │   │   └── trafficAI/
    │   │       ├── main.lua
    │   │       ├── core/
    │   │       │   ├── driver.lua
    │   │       │   ├── perception.lua
    │   │       │   ├── decision.lua
    │   │       │   ├── memory.lua
    │   │       │   ├── stateMachine.lua
    │   │       │   └── goals.lua
    │   │       ├── drivers/
    │   │       │   ├── driverTypes.lua
    │   │       │   ├── personalities.lua
    │   │       │   └── skills.lua
    │   │       ├── models/
    │   │       │   ├── carFollowing.lua
    │   │       │   ├── laneChange.lua
    │   │       │   └── perceptionThresholds.lua
    │   │       ├── behaviors/
    │   │       │   ├── driving.lua
    │   │       │   ├── overtaking.lua
    │   │       │   ├── intimidation.lua
    │   │       │   ├── ragebait.lua
    │   │       │   ├── defensive.lua
    │   │       │   └── emergencies.lua
    │   │       ├── traffic/
    │   │       │   ├── vehicles.lua
    │   │       │   ├── lanes.lua
    │   │       │   ├── intersections.lua
    │   │       │   └── trafficFlow.lua
    │   │       ├── environment/
    │   │       │   ├── weather.lua
    │   │       │   ├── timeOfDay.lua
    │   │       │   └── roadConditions.lua
    │   │       ├── config/
    │   │       │   ├── driverProfiles.json
    │   │       │   ├── probabilities.json
    │   │       │   └── difficulty.json
    │   │       ├── util/
    │   │       │   ├── log.lua
    │   │       │   ├── mathUtils.lua
    │   │       │   └── tableUtils.lua
    │   │       └── debug/
    │   │           ├── overlay.lua
    │   │           └── inspector.lua
    │   │
    │   └── vehicle/extensions/
    │       └── trafficAI/
    │           ├── actuator.lua
    │           ├── signals.lua
    │           └── microDriving.lua
    │
    ├── settings/inputmaps/
    │   └── keyboard_trafficAI.json
    │
    └── ui/modules/apps/TrafficAI/
        ├── app.html
        ├── app.js
        └── app.json
```

---

## 3. Qué es cada carpeta y por qué está donde está

### `mod/scripts/trafficAI/modScript.lua`
Punto de entrada. BeamNG busca automáticamente `scripts/*/modScript.lua` dentro de cualquier
mod montado y lo ejecuta al cargar. Es el único archivo que se ejecuta solo; todo lo demás
se carga desde aquí. Contenido típico (tomado de `fluidspill`):

```text
setExtensionUnloadMode(<nombre_extensión>, "manual")
extensions.load(<nombre_extensión>)
```

### `mod/lua/ge/extensions/trafficAI/` — el cerebro (GameEngine Lua)
Aquí vive **toda la lógica de decisión**. GE Lua ve el mundo entero: todos los vehículos, sus
posiciones, el mapa de carreteras, la hora, el clima. Es el único sitio donde un conductor
puede razonar sobre *otros* conductores, que es el pilar del documento de diseño (secciones 7-11).

Nombres de extensión: la ruta se convierte en el nombre con `_`. Por ejemplo
`lua/ge/extensions/trafficAI/core/driver.lua` → extensión `trafficAI_core_driver`.

| Carpeta | Sección del diseño | Responsabilidad |
|---|---|---|
| `core/driver.lua` | §2, §18 | La entidad conductor: agrupa identidad, personalidad, habilidades, estado, memoria y objetivo |
| `core/perception.lua` | §5.4, §16 | Qué ve el conductor y con cuánto retraso/error según su percepción |
| `core/decision.lua` | §16 | El bucle: generar acciones candidatas → evaluar riesgo → elegir |
| `core/memory.lua` | §14 | Memoria temporal: qué pasó, con quién, hace cuánto |
| `core/stateMachine.lua` | §13, §17 | Los 17 estados y las transiciones entre ellos |
| `core/goals.lua` | §15 | Objetivos temporales que persisten varios segundos |
| `drivers/driverTypes.lua` | §3 | Los 20 tipos (Slow, Aggressive, Elderly...) |
| `drivers/personalities.lua` | §4, §12 | Paciencia, agresividad, prudencia, confianza, tolerancia, temperamento + preferencia de técnicas (claxon vs luces vs ragebait) |
| `drivers/skills.lua` | §5 | Experiencia, reflejos, control, percepción, decisiones, conocimiento de zona |
| `models/*` | §5, §6 | Matemáticas neutras y reutilizables: seguimiento (tipo IDM), utilidad de cambio de carril (tipo MOBIL, con factor de cortesía), umbrales de percepción (tipo Wiedemann). No saben nada de personalidad; reciben parámetros y devuelven números |
| `behaviors/driving.lua` | §6 | Conducción natural: micro-variaciones, no matemáticamente perfecta |
| `behaviors/overtaking.lua` | §16 | Adelantamientos |
| `behaviors/intimidation.lua` | §8, §9 | Claxon, luces altas, acercarse/alejarse — y las distintas reacciones del de delante |
| `behaviors/ragebait.lua` | §10, §11 | Provocación y ragebait extremo (probabilidad baja) |
| `behaviors/defensive.lua` | §9 | Ceder, aumentar distancia, maniobra defensiva |
| `behaviors/emergencies.lua` | §5.2 | Reacción a frenadas bruscas, obstáculos, accidentes cercanos |
| `traffic/*` | §7 | Registro de vehículos vigilados, carriles, intersecciones, densidad de tráfico |
| `environment/*` | §2 (Contexto) | Clima, hora del día, estado de la carretera |
| `gameplay/traffic/roles/trafficAI.lua` | — | Enganche con el sistema nativo. **La ruta es obligatoria**: `trafficUtils.lua:152` busca los roles solo en `/lua/ge/extensions/gameplay/traffic/roles/<nombre>.lua` |
| `config/*.json` | §19 | Datos ajustables sin tocar Lua: perfiles, probabilidades, dificultad |
| `util/*` | — | Log, matemáticas, tablas |
| `debug/*` | — | Overlay en pantalla e inspector de un conductor concreto |

### `mod/lua/vehicle/extensions/trafficAI/` — las manos (Vehicle Lua)
Vehicle Lua corre **dentro de cada coche**, en su propio hilo, a la frecuencia de la física.
Solo puede tocar ese vehículo, pero es lo único que puede accionar cosas con precisión:

- `actuator.lua` — claxon, luces altas, intermitentes, ráfagas.
- `signals.lua` — patrones de luces (ráfaga simple, múltiple, prolongada, alternar).
- `microDriving.lua` — las micro-correcciones de §6: moverse dentro del carril, variar
  levemente la velocidad, frenar/acelerar de forma orgánica.

Regla de oro: **el GE decide, el vehículo ejecuta.** La comunicación va en un solo sentido
(`queueLuaCommand`) y hay que mantenerla ligera porque cruza hilos.

### `mod/lua/ge/extensions/core/input/actions/trafficAI.json` + `mod/settings/inputmaps/`
Atajos de teclado (por ejemplo, activar/desactivar el overlay de debug). Las rutas son fijas,
BeamNG las escanea por convención.

### `mod/ui/modules/apps/TrafficAI/`
App de UI opcional para ver en tiempo real el tipo, personalidad, estado y objetivo del
conductor que tienes delante. Muy útil para depurar un sistema que, por diseño, produce
comportamientos que nadie programó explícitamente.

---

## 4. Cómo se engancha con el tráfico nativo de 0.39.4

Esto es lo importante y la razón de que exista `roles/`.

El juego ya trae en `lua/ge/extensions/gameplay/traffic/`:

- `traffic.lua` — gestiona spawn, pool de vehículos, densidad.
- `vehicle.lua` — un objeto por coche de tráfico, con `honkHorn(duration)`, control de faros,
  detección de colisiones, y envío de `ai.setAggression(x)` al vehículo.
- `baseRole.lua` — clase base de "rol", con `generatePersonality()` / `applyPersonality()`,
  `setTarget(id)`, `setAction(name)`, y los hooks `onUpdate`, `onTrafficTick`, `onCollision`,
  `onOtherCollision`, `onCrashDamage`, `onOtherEvent`.
- `roles/` — `standard.lua`, `police.lua`, `suspect.lua`, `empty.lua`.

La personalidad nativa es mínima: tres valores (`aggression`, `patience`, `bravery`) generados
con una gaussiana, y de esos tres solo `aggression` llega realmente a la IA de conducción.

**El plan es extender ese sistema, no reemplazarlo.** `gameplay/traffic/roles/trafficAI.lua` es un rol
nuevo que sustituye a `standard` y que, en sus hooks, delega en `core/decision.lua`. Así
heredamos gratis el spawn, el enrutado, el respawn y toda la física de conducción, y nos
concentramos en lo que el documento pide de verdad: identidad, estado, memoria e interacción
entre conductores.

Lo que ya existe y podemos aprovechar directamente:

| Necesidad del diseño | Ya existe en 0.39.4 |
|---|---|
| Claxon (§8) | `vehicle.lua:honkHorn(duration)` |
| Faros (§8) | `electrics.setLightsState(0/1)` vía `queueLuaCommand` |
| Agresividad de conducción | `ai.setAggression()` |
| Objetivo/target de un conductor (§14) | `baseRole:setTarget(id)` |
| Detectar que A golpeó a B (§14) | `onCollision` / `onOtherCollision` / `onOtherEvent` |
| Contexto de tráfico | `trafficUtils.lua`, `roadTracking.lua` |

Lo que **no** existe y hay que construir: los 20 tipos, las 6 habilidades, los 17 estados, la
memoria temporal, los objetivos temporales, la intimidación, el ragebait y la conducción no
matemática.

---

## 5. Cómo se instala durante el desarrollo

BeamNG 0.39.4 monta mods sin comprimir desde `mods/unpacked/<nombre>/` (confirmado en
`lua/ge/extensions/core/modmanager.lua`, línea 626). Para desarrollar, el contenido de `mod/`
va en:

```text
C:\Users\yolor\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\trafficAI\
```

Esa carpeta todavía no existe; se crea al desplegar. Un enlace simbólico desde `mod/` evita
tener que copiar archivos en cada cambio.

Para publicar, se comprime el **contenido** de `mod/` (no la carpeta `mod/` en sí) en un `.zip`
que se coloca en `mods/`. La carpeta `mod_info/` que se ve en los mods descargados la genera
el repositorio oficial al publicar; no hay que crearla a mano.

---

## 6. Estado actual

Primer slice implementado: identidad, personalidad, habilidades, estados y enganche con el rol nativo.

1. Decidir el alcance de la primera versión jugable (probablemente: identidad + personalidad +
   estados + un solo comportamiento visible, como la intimidación con claxon).
2. Escribir `modScript.lua` y `main.lua` para tener el mod cargando y logueando en consola.
3. Definir el formato de `driverProfiles.json` antes de escribir la lógica que lo consume.
