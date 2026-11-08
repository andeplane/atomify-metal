# Apple recognition research for Atomify

Researched 23 October 2026. App implementation reviewed at `131fff6`.

The strongest product direction is **understand matter by handling it in space**.
Apple has already recognized spatial science, tactile manipulation and immersive
storytelling. Atomify can bring these together through real molecular dynamics,
clear scientific explanations and a small number of memorable discoveries.

This report uses Apple's public editorial articles, award records, design
guidance and nomination documentation. It does not claim firsthand testing of
the comparison apps. Award winners, award finalists and WWDC examples are
different kinds of recognition. Apple's published praise explains qualities it
values; it does not expose the full selection process or establish a probability
of Atomify being featured. Recommendations below are our interpretation.

**What Apple explicitly asks for**

The [App Store featuring criteria](https://developer.apple.com/app-store/getting-featured/)
cover useful and approachable functionality, visual and interaction quality,
innovation, distinctiveness, accessibility, localization and a compelling product
page. A native interface is one part of that assessment.

In [Design great visionOS apps, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10086/),
Apple organizes its guidance around intentional design, immersion, comfort and
delight. It asks developers to identify a key moment that benefits from spatial
computing. Its examples include taking JigSpace models apart, room surfaces
affecting Super Fruit Ninja, and sound responding to interaction in Blackbox.
It also emphasizes restrained window layouts, comfortable reach, optional
movement and generous interaction targets.

The [immersive-experience guidelines](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences/)
recommend giving people control over immersion, supporting use without walking,
keeping passthrough useful, and directing attention with subtle cues. Mixed
reality can support a compelling experience while preserving the surroundings.

**Apps that received recognition, and what Apple praised**

| App | Verified recognition | Published reasons, paraphrased | Implication for Atomify — our inference |
| --- | --- | --- | --- |
| CellWalk | 2025 Apple Design Award Visuals and Graphics finalist; Apple developer profile published May 2026 | Detailed scientific structures, understandable explanations, approachable manipulation and deliberate visual focus. Its creator discusses authoritative data and student feedback. | A molecule needs an explanation and a discovery attached to it. Selecting one structure should reveal its role while surrounding detail recedes. |
| Metaballs | 2026 Apple Design Award Delight and Fun finalist | Spatial shapes respond to poking, pushing and separation; materials and lighting make manipulation appealing. | Reliable, legible response to the hand is central product quality. Atomify needs the consequence of each manipulation to be easy to see. |
| Taobao | 2025 Apple Design Award Interaction winner | Convincing 3D objects, smooth manipulation, considered placement and scale, and side-by-side comparison. | A matched-scale carbon-sheet/diamond comparison could communicate structure more clearly than switching between isolated catalogue entries. |
| What If…? An Immersive Story | 2024 Apple Vision Pro App of the Year | A narrative in which users participate through hand gestures, with cinematic scenes reinforcing their role. | Give the learner a purpose and a visible consequence for acting. A short scientific question can supply that purpose without a fictional plot. |
| Explore POV | 2025 Apple Vision Pro App of the Year | Convincing presence, rich audio, easy discovery by interests and recurring new experiences. | First-launch impact, thoughtful browsing and continuing content should reinforce each other. |
| djay | 2024 Apple Design Award Spatial Computing winner | Detailed, directly manipulable equipment and carefully composed environments support music-making. | Place useful interactions within reach and make the first action obvious. Feedback should reinforce the activity. |
| Caradise | 2026 Apple Design Award Visuals and Graphics finalist | Detailed cars, explorable interiors, environmental reflections and positional engine sound. | A coherent object with many understandable details can sustain attention. Visual polish needs to extend to the exhibit itself. |

Case sources: [CellWalk developer profile](https://developer.apple.com/news/?id=7qd3hzay),
[2025 Design Awards](https://developer.apple.com/design/awards/2025/),
[2026 Design Awards](https://developer.apple.com/design/awards/),
[What If…? editorial](https://apps.apple.com/us/story/id1781308137),
[Explore POV editorial](https://apps.apple.com/us/iphone/story/id1847900745),
and [2024 Design Awards](https://developer.apple.com/design/awards/2024/).
The current-year award page changes over time; its 2026 labels were checked on
the research date.

CellWalk is the closest comparison. Apple's profile describes rich colors,
focus through dimming unrelated structures, inspectable models, accessible
explanations and scientific provenance. The large atom counts in its publicity
describe visualization; they do not establish atomistic simulation at that scale.
Atomify should make its own dynamics useful to learning and avoid treating those
rendering counts as a directly comparable simulation benchmark.

**What this means for the current app**

This is a source audit, not a headset usability evaluation.

| Product quality | Current evidence | Remaining work |
| --- | --- | --- |
| A clear invitation | `LibraryView` has three journeys, a featured structure, a primary action and rotating previews. | Demonstrate that a newcomer reaches a meaningful interaction without coaching. |
| Authored discovery | The catalogue contains observation and interaction prompts; controls repeat them. | Add a short question/action/explanation sequence that responds to what the learner does. |
| Inspectable science | The renderer highlights candidate/grabbed atoms; graphs and aggregate statistics exist. | Add contextual element labels, local neighbors, measured distances/angles, and an explanation of the selected feature. |
| Scientific credibility | Separate documented AIREBO and Vashishta models; numerical and manipulation checks are recorded. | Bring concise provenance and model limitations into an accessible information layer. Keep visual bond thresholds distinct from chemical bond order. |
| Matter in the room | Observed cyan geometry, a real grid-readiness gate, release control and tracking-loss hold are implemented. | Prove one visibly correct interaction with a measured surface, then test partial scans, holes and relocalization on-device. |
| Sensory detail | Native 3D structures, hand response and a compact controls panel exist. | No app-level spatial-audio implementation was found. Consider restrained, optional interaction sonification with a visual equivalent. |
| Accessibility and comfort | Standard window controls, Observe mode, selected-state traits and Reduce Motion for the preview exist. | These do not establish accessible manipulation. Test larger text, color-independent cues, one-hand/alternative input, reach, contrast and spoken scientific descriptions. |

Implementation references:
[library](../Atomify/Library/LibraryView.swift),
[controls](../Atomify/Controls/ControlsView.swift),
[preview](../Atomify/Library/MoleculePreview.swift),
[interaction](../Atomify/Interaction/InteractionController.swift),
[room sensing](../Atomify/Interaction/RoomWalls.swift),
[catalogue](../Demos/demos.json), and
[release scope and validation](RELEASE.md).

**Recommended product changes, in order**

1. **Author the first minute around one discovery.** Introduce the benzene ring
   within reach. Guide opening a hand and pinching one highlighted atom. Show
   neighboring atoms respond to a gentle pull. Reveal a short explanation of
   the restoring behavior, with a measured distance. End with an obvious next
   question. A proposed first-run success criterion is that four of five new
   testers reach the first guided interaction within one minute without coaching.
   This is our acceptance target, not an Apple requirement.

2. **Build three short scientific journeys.** For methane, reveal four neighbors
   around carbon and measured H–C–H angles. For the carbon sheet and diamond,
   compare local threefold and fourfold interior coordination at matched visual
   atom size. For benzene, guide the already-tested C–H separation and return,
   showing distance history and explaining the driven empirical model. All
   measurements must come from the displayed state. Finite unpassivated
   structures do not measure bulk hardness, and guided reattachment does not
   establish spontaneous healing. Grow the library around additional questions
   with equally clear explanations and validated models.

3. **Make one room surface matter.** After usable geometry is available, guide
   a small particle stream toward a clearly indicated observed surface. Make the
   collision and its location unmistakable through restrained visual feedback
   and optional sound. The same collision must remain when the cyan scan is
   hidden. Partial sensing must never be described as complete room coverage.
   Keep the demonstration useful while seated and within a small mapped area.

4. **Complete the interaction and accessibility craft.** Make acquisition,
   holding, release, cancellation and recovery legible. Add an inspection mode
   that focuses one local structure and explains it in ordinary language.
   Scientific sound mappings must be identified as sonification; atoms are not
   being represented as producing literal audible notes. Provide equivalent
   visual information and a mute option. Comfortable seated use and alternative
   input belong in the product acceptance pass.

5. **Build evidence from actual learners and actual hardware.** Observe novices
   using the app, ask them to explain the idea afterward, and improve where
   their interpretation differs from the intended lesson. Test sustained frame
   timing, comfortable scale, tracking recovery and room collisions on Vision
   Pro. Keep host numerical validation and wearer acceptance separately recorded.

**Implemented from this research on 23 October**

The audit above describes the starting point at `131fff6`. The app now has five
journeys and fourteen curated experiments, including a Biology chapter and a
Changing matter chapter. The changes below implement the research priorities:

- **Authored discovery:** Look → Try → Discover cards carry a question, activity,
  explanation and model notes beside each live experiment. Held-particle distance
  changes can advance the interactive lesson; that feedback requires a current
  grab rather than attributing thermal movement to an old interaction.
- **Inspectable science:** the live graph supplies particle identity, local
  connections, minimum-image separation and mean local angle. Next particle and
  Focus neighbours offer a button-based route into inspection. Other particles
  remain visible with subdued rendering.
- **Spatial comparison:** actual saved carbon-sheet and diamond structures share
  a coordinate-to-display scale. Captions distinguish finite surfaces from ideal
  interior coordination and previews from live simulations.
- **Comfortable focus:** small molecules and DNA frame their actual content at
  32 cm rather than framing a large empty vacuum cell. True boundaries can still
  be shown explicitly. Pause, reset and Tools stay above the learning card.
- **Meaningful room feedback:** a separate guide uses a real observed triangle
  and current wearer pose. It highlights an actually observed particle approach
  and departure, clears on stale/replaced sensing, and remains when the full scan
  is hidden. It does not invent a complete room scan.
- **Restrained sound:** optional, quiet, rate-limited spatial tones mark successful
  grabs and measured room encounters. They default off and are labelled as
  authored feedback, with equivalent visual cues.
- **Credible content:** oxDNA2 DNA, fixed-topology solvated peptide, a coarse
  surfactant toy, LJ phase changes, mW ice melting and CHO ReaxFF oxidation each
  identify their representation and limits. Model-specific real-engine probes
  accompany the examples, including failures for conditions that miss their gate.

These changes implement lessons from the recognized apps; they do not establish
Apple endorsement. Headset comfort, newcomer comprehension, accessibility,
sustained performance and editorial nomination remain separate acceptance work.
See [release scope](RELEASE.md) and [the materials map](materials-learning-map.md).

**Prepare for editorial consideration**

The product story should demonstrate a learner discovering something by
manipulating matter. A short headset recording should show the real interaction,
the resulting explanation and one convincing room contact. Supporting material
should include a working build, scientific sources and limits, accessibility
coverage and observations from learner testing.

Apple provides [Featuring Nominations in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/).
Its operational help recommends at least three weeks of lead time and permits
up to five supporting URLs, including TestFlight links. The broader featuring
page mentions two weeks and up to three months for wider consideration. Plan
for at least three weeks and preferably more. Nomination is a separate editorial
submission; App Store approval alone does not establish featuring.

No nomination or external message was submitted during this research.
