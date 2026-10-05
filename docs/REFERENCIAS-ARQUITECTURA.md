# Investigación: cómo se estructuran otros sistemas de IA de tráfico

Búsqueda hecha el 2026-08-22 para validar la estructura de `mod/`. Dos frentes: mods reales de
BeamNG y la literatura de simulación de tráfico microscópico.

---

## 1. Mods de BeamNG que ya hacen algo parecido

### Advanced Traffic AI (twiks228) — el más útil, tiene código abierto

Repositorio: <https://github.com/twiks228/Advancedtrafficaibeamg>

Su árbol completo son 15 archivos Lua, todos planos en una sola carpeta:

```text
TrafficAI/lua/ge/extensions/gameplay/trafficAI/
├── trafficAICore.lua          ← orquestador
├── driverPersonality.lua
├── laneDiscipline.lua
├── dynamicLaneChanging.lua
├── speedLimits.lua
├── trafficSignals.lua
├── emergencyAvoidance.lua
├── accidentReaction.lua
├── aiAccidents.lua
├── vehicleStability.lua
├── policeResponse.lua
├── policeAPI.lua
├── playerInteraction.lua
├── vehicleDiversity.lua
└── uiNotifications.lua
```

**Lo que hace bien y conviene copiar:**

- **Pizarra compartida (blackboard).** `trafficAICore` mantiene una tabla `managed` indexada por
  ID de vehículo. Cada vehículo tiene un objeto de estado con velocidad, posición, carril,
  intermitentes, banderas de adelantamiento, referencia a personalidad, estado de accidente e
  interacción. Ese objeto es el bus de comunicación entre módulos.
- **Pipeline por tick con commit único.** En `onUpdate` recorre cada vehículo, llama a
  `update()` de cada módulo en orden — cada uno *modifica* el estado compartido, ninguno habla
  con el coche — y al final un solo `applyFinal()` traduce el estado deseado en comandos reales
  al vehículo. Esto evita que cinco módulos peleen mandando `queueLuaCommand` contradictorios,
  que es el error clásico en este tipo de mod.
- Hooks usados: `onUpdate`, `onVehicleSpawned`, `onVehicleDestroyed`, `onClientEndMission`.

**Lo que conviene NO copiar:**

- **Ignora `gameplay_traffic`.** Descubre coches con `getAllVehicles()` y filtra el del jugador
  y la policía. Eso significa reimplementar por su cuenta cosas que el juego ya resuelve
  (pooling, respawn, densidad, roles). Nuestro plan de engancharnos al sistema de roles nativo
  es menos frágil.
- **Estructura plana.** Con 15 archivos ya cuesta ubicarse; nuestro diseño tiene bastantes más
  piezas (20 tipos, 6 habilidades, 17 estados, memoria, objetivos, intimidación, ragebait), así
  que las subcarpetas se justifican.
- Su carpeta de mod incluye un `modInfo.json` en la raíz. **Verifiqué en el código del juego
  0.39.4 y no existe ninguna referencia a ese nombre** (`grep -rn "modInfo.json" lua/` no
  devuelve nada). No hace falta crearlo.

### Otros mods (sin código público, solo referencia de alcance)

- [Realistic AI Traffic Behaviors](https://www.nexusmods.com/beamngdrive/mods/285) — personalidades
  distintas, cambios de carril y adelantamientos dinámicos, densidad dinámica; reacciona a
  condiciones de carretera, clima, hora del día, accidentes y acciones del jugador.
- [AI Personalities Mod](https://www.beamng.com/threads/ai-personalities-mod-dynamic-driver-behaviors-for-beamng-traffic.105824/)
  en el foro oficial — marcado como **cancelado**. Vale la pena tenerlo presente: la idea no es
  nueva y a alguien ya se le atragantó.
- [Dynamic AI Traffic Mod](https://www.modland.net/beamng.drive-mods/other/dynamic-ai-traffic-mod.html)

**Conclusión sobre el estado del arte:** los mods existentes se quedan en 4-5 arquetipos fijos
(Pensioner / Normal / Aggressive / Distracted). Ninguno hace lo que pide tu documento: estados
temporales, memoria de a quién le pasó qué, objetivos que persisten, intimidación con respuesta
variable del otro conductor, ragebait. Ahí está el hueco.

---

## 2. Literatura de simulación de tráfico: qué llevan haciendo 40 años

### Modelo de Michon (1985): tres niveles de conducción

Es la referencia canónica. Divide la conducción en tres niveles jerárquicos, donde **los niveles
superiores coordinan y restringen a los inferiores**:

| Nivel | Escala de tiempo | Qué decide |
|---|---|---|
| **Estratégico** | minutos a horas | Planificación del viaje, ruta, objetivos generales |
| **Táctico** | segundos a minutos | Maniobras conscientes: adelantar, cambiar de carril, ceder |
| **Operacional** | fracciones de segundo | Subconsciente: mantenerse en el carril, corregir el volante |

Esto valida directamente el reparto GE Lua / Vehicle Lua de nuestra estructura:

```text
core/goals.lua              → estratégico  (GE)
core/decision.lua + behaviors/ → táctico   (GE)
vehicle/.../microDriving.lua   → operacional (Vehicle Lua, a frecuencia de física)
```

Y explica por qué la §6 de tu documento ("conducción natural", micro-correcciones) debe vivir en
el vehículo y no en el cerebro: es otro nivel y otra frecuencia.

Fuentes: [Michon, "A critical view of driver behavior models" (PDF original)](https://jamichon.nl/jam_writings/1985_criticial_view.pdf),
[diagrama del modelo](https://www.researchgate.net/figure/Michons-three-levels-of-control-simplified_fig1_337383203).

### IDM + MOBIL: el par estándar

Casi todo simulador microscópico usa dos modelos separados:

- **IDM (Intelligent Driver Model)** — modelo de *seguimiento*. La aceleración o frenada de un
  conductor depende solo de su velocidad y de la posición y velocidad del vehículo de delante.
  Es el que produce distancias de seguridad, "acordeón" en atascos, etc.
- **MOBIL** — modelo de *cambio de carril*. Decide en función de todos los vehículos vecinos.

Lo interesante para nosotros: **MOBIL tiene un parámetro llamado "politeness factor"** que mide
cuánto pesa la molestia causada a otros conductores en la propia decisión. Bajarlo produce
conductores que cierran huecos y se meten sin miramientos; subirlo produce conductores corteses.
Eso es literalmente tu "Tolerancia" y tu "Courteous Driver" de la §4, pero con formulación
numérica ya probada. No hay que inventarlo.

Fuentes: [MOBIL (paper)](https://www.researchgate.net/publication/239439179_General_Lane-Changing_Model_MOBIL_for_Car-Following_Models),
[An Open-Source Microscopic Traffic Simulator](https://arxiv.org/pdf/1012.4913),
[Interactive Traffic Simulation](https://www.imaginary.org/sites/default/files/trafficsimulation_documentation.pdf).

### Wiedemann: umbrales de percepción (el modelo de VISSIM)

Este es el que más se parece a lo que pides en la §5.4. En vez de asumir que el conductor conoce
la distancia exacta al de delante, define **umbrales de percepción**: el conductor solo reacciona
cuando la diferencia de velocidad o la distancia cruza cierto punto. El conductor se encuentra
siempre en uno de cuatro regímenes: **conducción libre, aproximación, seguimiento o frenada**, y
solo cambia de régimen al cruzar un umbral ("action point").

Es exactamente el mecanismo que hace que un conductor con percepción baja reaccione tarde aunque
tenga buenos reflejos — la distinción que haces en tu §5.4. Los umbrales se escalan por
conductor y ya está: sale gratis.

Fuentes: [Analysis of the Wiedemann Car Following Model (PDF)](https://onlinepubs.trb.org/onlinepubs/conferences/2011/RSS/3/Higgs,B.pdf),
[Review of driving-behaviour simulation: VISSIM and AI approaches](https://pmc.ncbi.nlm.nih.gov/articles/PMC10878954/).

### Arquitectura de agente: percepción → planificación → control

Los simuladores de conducción autónoma (SUMO, CARLA) estructuran cada agente en capas de
**percepción, planificación, control y comunicación**, manteniendo la capa estratégica separada
de la táctico-reactiva. Es la misma separación que ya tiene `core/` en nuestra estructura.

Fuentes: [An overview of agent-based traffic simulators](https://www.sciencedirect.com/science/article/pii/S2590198221001913),
[SUMO + CARLA framework](https://www.researchgate.net/publication/355220243_A_Novel_Traffic_Simulation_Framework_for_Testing_Autonomous_Vehicles_Using_SUMO_and_CARLA).

---

## 3. Cómo decide un NPC: utility AI vs. árbol de comportamiento

Tu §16 describe: *generar posibles acciones → evaluar riesgo → seleccionar acción*. Eso es
**Utility AI**, no un árbol de comportamiento.

- **Utility AI**: se asigna un valor de utilidad a cada acción posible y se elige la de mayor
  puntuación. Las funciones de utilidad convierten el estado del mundo en puntuaciones
  normalizadas de 0 a 1.
- **Behavior Tree**: árbol jerárquico de condiciones y acciones con secuencias, selectores y
  decoradores. Bueno para lógica escrita a mano; malo para "que emerjan situaciones que el
  desarrollador nunca programó", que es tu §20.

La combinación habitual en la industria: **utility para priorizar, árbol o máquina de estados
para ejecutar el plan elegido, y percepción alimentando a ambos**, con una **blackboard** que
mantiene el estado accesible a todos los nodos.

Eso encaja pieza por pieza con lo que tenemos: `core/perception.lua` alimenta,
`core/decision.lua` puntúa, `core/stateMachine.lua` ejecuta y `core/driver.lua` es la blackboard.
Y la personalidad no es más que **pesos que deforman las funciones de utilidad** — un conductor
con agresividad 90 y paciencia 20 puntúa "adelantar" mucho más alto ante el mismo estímulo. Eso
es lo que da tu §1: misma situación, respuestas distintas.

Fuentes: [Utility-Based AI Systems](https://recited.io/kb/ai-in-game-development/npc-behavior-and-intelligence/utility-based-ai-systems/),
[Game AI Planning: GOAP, Utility, and Behavior Trees](https://tonogameconsultants.com/game-ai-planning/),
[Behavior trees for AI: how they work](https://www.gamedeveloper.com/programming/behavior-trees-for-ai-how-they-work),
[Designing AI Agents' Behaviors with Behavior Trees](https://towardsdatascience.com/designing-ai-agents-behaviors-with-behavior-trees-b28aa1c3cf8a/).

---

## 4. Cambio que esto produce en la estructura

Se añadió una carpeta:

```text
mod/lua/ge/extensions/trafficAI/models/
```

Separa las **matemáticas** de la **personalidad**:

- `models/` — modelos numéricos neutros y reutilizables: seguimiento tipo IDM, utilidad de cambio
  de carril tipo MOBIL, umbrales de percepción tipo Wiedemann. No saben nada de tipos de
  conductor; reciben parámetros y devuelven números.
- `behaviors/` — la capa con intención y personalidad, que *usa* `models/` alimentándolo con los
  parámetros del conductor concreto.

Sin esa separación, la fórmula de seguimiento acabaría copiada y pegada dentro de `driving.lua`,
`overtaking.lua` e `intimidation.lua`, cada una con su variante ligeramente distinta.

El resto de la estructura se mantiene: la investigación la confirma en vez de contradecirla.

---

## Fuentes

- <https://github.com/twiks228/Advancedtrafficaibeamg>
- <https://www.nexusmods.com/beamngdrive/mods/285>
- <https://www.beamng.com/threads/ai-personalities-mod-dynamic-driver-behaviors-for-beamng-traffic.105824/>
- <https://www.modland.net/beamng.drive-mods/other/dynamic-ai-traffic-mod.html>
- <https://documentation.beamng.com/tutorials/ai/>
- <https://jamichon.nl/jam_writings/1985_criticial_view.pdf>
- <https://www.researchgate.net/figure/Michons-three-levels-of-control-simplified_fig1_337383203>
- <https://www.researchgate.net/publication/239439179_General_Lane-Changing_Model_MOBIL_for_Car-Following_Models>
- <https://arxiv.org/pdf/1012.4913>
- <https://www.imaginary.org/sites/default/files/trafficsimulation_documentation.pdf>
- <https://onlinepubs.trb.org/onlinepubs/conferences/2011/RSS/3/Higgs,B.pdf>
- <https://pmc.ncbi.nlm.nih.gov/articles/PMC10878954/>
- <https://www.sciencedirect.com/science/article/pii/S2590198221001913>
- <https://www.researchgate.net/publication/355220243_A_Novel_Traffic_Simulation_Framework_for_Testing_Autonomous_Vehicles_Using_SUMO_and_CARLA>
- <https://recited.io/kb/ai-in-game-development/npc-behavior-and-intelligence/utility-based-ai-systems/>
- <https://tonogameconsultants.com/game-ai-planning/>
- <https://www.gamedeveloper.com/programming/behavior-trees-for-ai-how-they-work>
- <https://towardsdatascience.com/designing-ai-agents-behaviors-with-behavior-trees-b28aa1c3cf8a/>
