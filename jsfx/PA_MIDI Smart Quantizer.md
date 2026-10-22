# PA MIDI Smart Quantizer

JSFX autonome en EEL2 pour jouer un instrument virtuel à travers une sélection libre de hauteurs. Les modes **Quantize**, **Relative** et **Mapping** sont opérationnels. Aucun échantillon de retard ni fenêtre d'analyse ne sont ajoutés : les événements sont traités dans leur bloc avec leur offset d'origine. La latence de la carte audio et de l'instrument reste celle de REAPER.

## Installation et premier essai

1. Dans REAPER, ouvrir **Options → Show REAPER resource path in explorer/finder**.
2. Copier seulement `PA_MIDI Smart Quantizer.jsfx` dans `Effects`, éventuellement dans un sous-dossier `PA`. Il n'a aucune dépendance.
3. Ajouter **JS: PA MIDI Smart Quantizer** sur une piste, **avant l'instrument virtuel**. Actualiser la liste des effets si nécessaire.
4. Choisir le clavier comme entrée MIDI, armer la piste et activer le monitoring.
5. Choisir **Relative**, **Reference: Base**, **Root: C**, **Scale: Major pentatonic** (C, D, E, G, A). Tenir C4 et jouer D4, A3, D4, A3, en relâchant ces notes entre les frappes : les sorties successives sont **C4, D4, A3, C4, G3**. Le premier D4 arrête le son du C4 initial ; sa touche tenue reste la référence logique.

Les noms affichés suivent la convention **C4 = MIDI 60**, indépendamment de l'offset d'octave configuré dans REAPER. Les claviers INPUT et OUTPUT regroupent toutes les octaves ; les lignes de notes au-dessus donnent les octaves réelles. Le nombre MIDI exact apparaît dans LAST et REFERENCE.

## Commandes

| Commande | Fonction |
| --- | --- |
| Quantize | Note autorisée la plus proche de chaque entrée, sur toute la plage 0–127. |
| Relative | La touche de référence définit la commande d'intervalle ; cette commande avance dans les notes autorisées depuis la dernière sortie. |
| Reference: Base / Last note | Dans Relative, choisir l'entrée de base tenue ou la dernière entrée ayant produit une sortie comme référence d'intervalle. |
| Mapping | Une classe de sortie pour chacune des 12 classes d'entrée ; la sélection de gamme est ignorée. Cliquer sur les cases de sortie. |
| Tie: Down / Up | En cas de distance égale, choisir la candidate la plus basse / haute. En Relative, un triton commande une quarte / quinte. |
| Channel | Appliquer la transformation de hauteur à tous les canaux ou à un canal précis. Les références et le sustain sont indépendants sur chacun des 16 canaux. |
| Root / Scale | Chromatique, majeur, mineur naturel, pentatoniques majeure et mineure, dorien, mixolydien, tons entiers, triades majeure et mineure. |
| Clavier ALLOWED NOTES | Activer/désactiver librement chaque classe, sur toutes les octaves. Une modification manuelle passe la gamme en Custom. |
| Reset: chromatic | Réactiver les 12 classes ; les autres réglages sont conservés. |
| Identity mapping | Restaurer C→C, C♯→C♯, etc. |
| PANIC | Couper les sorties du bus traité, relâcher les pédales et réinitialiser les références. |
| Sustain: Thru / Capture | Thru par défaut : transmettre CC64 et les relâchements à l'instrument. Capture activé : intercepter CC64 et gérer le maintien dans le plugin. |

Le vert indique la sélection ou les notes de sortie, le bleu les entrées et l'or la référence. La ligne BASE ou LAST NOTE montre la référence entrée/sortie et CURSOR la dernière sortie, qui peut déjà être relâchée. En mode Last note, la référence reste affichée même si toutes les touches sont relâchées. Elle suit le dernier canal joué, ou un autre canal ayant encore une référence. Une base arrêtée reste visible dans INPUT tant que sa touche est tenue, mais disparaît d'OUTPUT. L'interface se redimensionne proportionnellement ; son format initial est 820 × 720.

Les paramètres sont des sliders JSFX cachés : ils restent accessibles dans **Param**, automatisables et enregistrés dans le projet et les presets FX REAPER. Le bouton Panic correspond au paramètre à bascule « Panic (toggle) » : chaque changement de valeur déclenche l'action.

## Placement Relative

Chaque canal possède une **référence d'entrée** et un **curseur de sortie cumulatif**. La première note est quantifiée vers la hauteur autorisée la plus proche, puis initialise les deux états. Le sélecteur sous le clavier distingue deux variantes :

- **Base** (par défaut) : la première touche encore tenue sert de référence d'entrée. Les écarts restent calculés par rapport à elle ; le curseur suit la dernière sortie.
- **Last note** : l'écart est calculé depuis la dernière entrée ayant produit une sortie. Le couple entrée/sortie est mémorisé après son relâchement, y compris quand aucune touche ne reste enfoncée. Chaque nouvelle note continue donc la chaîne. **Panic** démarre une nouvelle phrase ; l'arrêt/pause du transport et les messages de réinitialisation MIDI effacent également cet historique.

```text
intervalle = nouvelle entrée - référence d'entrée choisie (Base ou Last note)
pas = nombre de degrés correspondant à cet intervalle musical
nouvelle sortie = avancer de ces pas autorisés depuis la dernière sortie
```

Le mode Relative interprète ainsi un intervalle musical comme une commande de déplacement dans la sélection. Une seconde mineure ou majeure (1 ou 2 demi-tons) avance d'un degré ; une tierce mineure ou majeure (3 ou 4 demi-tons) avance de deux degrés ; une quarte de trois, une quinte de quatre, une sixte de cinq et une septième de six. Un triton est une quarte avec Tie Down ou une quinte avec Tie Up ; chaque octave d'entrée ajoute sept degrés. Le signe de l'intervalle donne le sens. Un pas est la prochaine note autorisée disponible dans ce sens, toutes octaves confondues. Dans une sélection clairsemée, ces déplacements peuvent donc dépasser une octave.

Exemple en **Base**, avec C, D, E, G et A autorisés. **La touche C4 reste tenue ; D4 et A3 sont relâchés après chaque frappe.**

| Entrée | Écart au C4 de référence | Déplacement depuis la dernière sortie | Sortie |
| --- | --- | --- | --- |
| C4 / 60 tenu | Première note | Initialisation | C4 / 60 |
| D4 / 62 | +2 demi-tons, seconde ascendante | C4 → D4 : un degré | D4 / 62 |
| A3 / 57 | −3 demi-tons, tierce descendante | D4 → C4 → A3 : deux degrés | A3 / 57 |
| D4 / 62 | +2 demi-tons, seconde ascendante | A3 → C4 : un degré | C4 / 60 |
| A3 / 57 | −3 demi-tons, tierce descendante | C4 → A3 → G3 : deux degrés | G3 / 55 |

La même entrée en **Last note** produit **C4, D4, G3, D4, G3** : après D4, A3 commande une quarte descendante de trois degrés, mesurée depuis le dernier D4 d'entrée. Le retour D4 commande ensuite trois degrés vers le haut depuis A3. Ce fonctionnement est également disponible sans maintenir C4.

**Dès le premier Note On relatif réussi, le Note Off de la base est envoyé au même offset, avant le nouveau Note On.** Le plugin conserve sa hauteur d'entrée/sortie dans la référence, mais lui retire la propriété du son. Une commande muette ou un canal exclu ne coupe pas la base. Le relâchement ultérieur de cette touche ne réémet pas de Note Off : il ne peut pas couper une autre note relative revenue sur la même hauteur. Le retour C4 de l'exemple est donc une nouvelle attaque, avec sa propre vélocité et son propre relâchement. L'arrêt d'une base devenue référence après un relâchement suit cette même règle lors de la prochaine commande relative.

En **Capture sustain**, cette coupure de base est immédiate et contourne le maintien interne. En **Thru**, le Note Off est envoyé sans modifier CC64 ; si l'instrument maintient encore cette hauteur avec sa propre pédale, il reste maître de ce sustain.

Le relâchement d'une note secondaire ne change pas le curseur : le déplacement suivant continue depuis la dernière sortie. En Base, la référence d'entrée reste la touche de base ; en Last note, le dernier couple entrée/sortie reste en mémoire. Les autres hauteurs actives ne sont pas déplacées. La nouvelle sortie peut croiser d'autres voix tenues : son sens est celui de la commande appliquée au curseur, pas une obligation de rester au-dessus ou en dessous de la sortie de référence.

Les sorties occupées par d'autres notes de ce canal sont sautées lors du parcours. La hauteur associée à la base logique peut être rejointe. Si plusieurs notes possèdent déjà une même hauteur, leurs propriétaires sont comptés séparément ; retirer la propriété de la base ne coupe pas les autres propriétaires. Les répétitions d'une même note de sortie partagée restent legato tant qu'un propriétaire la maintient.

Si le nombre de pas ne peut pas être parcouru entre 0 et 127, la nouvelle note est muette ; le curseur et la dernière référence jouée restent inchangés. Une sélection vide rend toutes les nouvelles notes muettes. Rejouer exactement l'entrée de référence revient sur sa hauteur de sortie, ou la hauteur autorisée disponible la plus proche si la sélection a changé.

En **Base**, dès que la touche de référence est relâchée, la plus ancienne touche encore enfoncée et ayant une hauteur de sortie mémorisée devient la référence. Sa hauteur de sortie devient le nouveau curseur. Une note muette faute de candidate n'est pas une référence. Quand aucune touche correspondante ne reste enfoncée, référence et curseur sont réinitialisés ; la prochaine note repart d'une quantification absolue en excluant les hauteurs encore réservées par Capture sustain. En **Last note**, les changements de touches tenues ne remettent pas le couple entrée/sortie à zéro.

Passer de Last note à Base réinitialise le curseur depuis la base encore tenue, ou efface l'historique si aucune base ne reste. Passer à Last note conserve le dernier couple entrée/sortie courant. Ces changements ne relancent pas une base déjà arrêtée.

Une touche déjà autorisée reste une commande relative : sa sortie peut donc différer de sa hauteur d'entrée. Pour transformer chaque touche indépendamment vers sa hauteur autorisée la plus proche, utiliser **Quantize**.

## Note Off, répétitions et collisions

Une réserve fixe de **4 096 voix** conserve, pour chaque Note On, son canal, sa hauteur d'entrée, sa sortie exacte, son état physique, son ordre d'arrivée et un indicateur de propriété du son. Ce dernier distingue une base encore tenue mais déjà arrêtée d'une note toujours audible pour le plugin. Chaque paire `(canal, note d'entrée)` possède une file **FIFO**. Les Note On de vélocité zéro suivent le chemin Note Off. Les relâchements des sorties actives conservent leur offset et leur vélocité, et utilisent la sortie mémorisée, même si la configuration a changé. Le Note Off anticipé de la base utilise une vélocité de relâchement nulle.

MIDI 1.0 ne donne pas d'identifiant distinct aux répétitions superposées d'une même note sur le même canal. Le premier Note Off libère donc le plus ancien Note On de cette entrée. Un Note Off sans entrée correspondante est absorbé pour éviter de couper une autre touche transformée vers cette hauteur.

En Quantize et Mapping, plusieurs entrées peuvent converger vers la même sortie. En Relative, une commande peut rejoindre une hauteur déjà possédée par une autre note, notamment lors d'une répétition de l'entrée de référence. Dans ces cas, une seule paire Note On/Note Off est envoyée pour la hauteur partagée : la première vélocité est utilisée et le Note Off attend le dernier propriétaire. Cela conserve la note jusqu'au dernier relâchement et évite les notes bloquées dans les synthétiseurs qui comptent les Note On. **Les notes superposées partageant une sortie jouent donc legato, sans nouvelle attaque ni nouvelle vélocité.** Une nouvelle commande Relative est recalculée à chaque Note On, y compris lors d'une répétition d'entrée. Une base déjà arrêtée n'est plus propriétaire : une nouvelle note peut attaquer à nouveau sa hauteur.

En Relative, les sorties occupées autres que celle de la référence sont exclues du parcours. Les canaux différents peuvent employer la même hauteur. Les collisions déjà présentes avant un passage de Quantize/Mapping vers Relative restent inchangées jusqu'à leur relâchement.

## Sustain et contrôleurs

**Thru est le réglage par défaut.** Les messages CC64 sont transmis sans changement de canal, de valeur ni d'offset, y compris les valeurs de demi-pédale. Les Note Off transformés partent dès le relâchement physique des touches. Le plugin ne réserve pas les hauteurs retenues uniquement par la pédale de l'instrument : il appartient à l'instrument de gérer le sustain et les nouvelles attaques. L'affichage OUTPUT représente alors les touches possédées par le plugin, sans prétendre connaître les voix encore audibles dans l'instrument.

**Capture est une option explicite**, accessible par le bouton `Sustain: Capture` ou le paramètre `Capture sustain`. Le plugin intercepte alors CC64, sans le transmettre, et suit son état indépendamment sur chaque canal. Il diffère les Note Off tant que CC64 est au moins égal à 64, puis les envoie à l'offset exact de levée de pédale. Les voix ainsi maintenues restent dans OUTPUT et sont exclues des nouvelles candidates Relative ; elles ne servent plus de référence physique. Un instrument qui ignore CC64 bénéficie aussi de ce maintien. Les valeurs intermédiaires sont interprétées comme une pédale binaire en Capture.

Un changement Thru→Capture alors que la pédale est enfoncée remet d'abord CC64 à zéro dans l'instrument pour lui retirer le maintien ; les voix déjà relâchées et conservées uniquement par cet instrument peuvent donc s'arrêter à ce moment. Le plugin reprend immédiatement l'état physique courant de la pédale pour les relâchements suivants. Dans l'autre sens, il transmet d'abord la valeur physique courante de CC64, puis les Note Off en attente : l'instrument reprend ainsi le maintien jusqu'à la vraie levée de pédale. Ces transferts ont lieu à l'offset zéro du bloc de changement. Panic garde son rôle de coupure explicite et remet les pédales à zéro dans les deux modes.

Les contrôleurs, pitch bends, program changes, channel pressure et messages système sont transmis. Le polyphonic aftertouch suit les hauteurs transformées, éventuellement plusieurs sorties si des répétitions traversent un changement de mapping. Les SysEx sont transmis automatiquement par `midirecv`.

CC121 libère les voix retenues par CC64 avant de transmettre Reset All Controllers. CC120, CC123 et les messages de mode de canal CC124–127 coupent leur canal et vident aussi ses files d'entrée : ces messages terminent la phrase MIDI et l'émetteur n'est pas obligé d'envoyer ensuite les Note Off individuels. La phrase suivante repart ainsi sans anciennes associations. MIDI Stop déclenche Panic ; System Reset déclenche Panic et vide toutes les files d'entrée, avant transmission. Les autres pédales (sostenuto CC66, hold CC69) sont transmises sans modèle de réservation spécifique ; Panic les remet à zéro.

Le sélecteur Channel concerne la transformation de hauteur. Le suivi des durées et des répétitions reste actif sur les 16 canaux du bus, afin qu'un changement de filtre pendant une note ne perde pas son relâchement. L'option Capture concerne également les 16 canaux du bus ; en Thru, CC64 les traverse tous sans modification.

## Changements pendant le jeu et Panic

Les changements de mode, de sélection, de Tie Break, de canal ou de mapping affectent **uniquement les prochains Note On**, au bloc suivant. Les notes déjà actives gardent leur sortie et leur propriétaire. Elles peuvent donc temporairement sortir de la nouvelle gamme. Reset chromatic suit cette même règle ; il ne coupe pas un accord. Le changement de politique sustain suit la procédure de transfert décrite ci-dessus.

Panic envoie les Note Off nécessaires, CC64/66/69 à zéro, All Notes Off et All Sound Off sur les canaux utilisés. Il retire les voix sous sustain et les références. Les touches encore physiquement enfoncées laissent des entrées muettes dans leurs files, pour absorber leurs futurs Note Off : un ancien relâchement ne peut ainsi pas couper une nouvelle pression de la même touche. Relâcher toutes les touches vide ces entrées.

La transition lecture/enregistrement→arrêt/pause déclenche la même sécurité, à l'offset zéro du prochain bloc. Le jeu en direct reste possible à l'arrêt. `ext_noinit` évite la perte de l'état au démarrage de lecture ; une réinitialisation supplémentaire demandée par l'hôte déclenche une coupure au prochain bloc. Les voix actives ne sont jamais sauvegardées dans le projet.

En cas de saturation de la réserve, les nouveaux Note On sont rendus muets et comptabilisés par entrée. Leurs relâchements sont absorbés dans l'ordre, sans émission de Note On non suivi et sans allocation supplémentaire. La capacité se libère en relâchant les touches et le sustain.

## Mapping et limites MIDI

Chaque classe d'entrée est remplacée par la classe configurée dans **la même octave MIDI**, indépendamment de la gamme. Par exemple C3→E3 et C4→E4. La dernière octave MIDI est incomplète : si une transformation dépasse 127, sa sortie est descendue d'une octave, en conservant sa classe. Exemple G9 / 127→B8 / 119. Aucun événement émis ne contient une hauteur hors de 0–127.

Le traitement porte sur le **bus MIDI 1 de REAPER** (`midi_bus == 0`). Les 15 autres bus traversent l'effet sans transformation ni mélange avec les références ou propriétaires du premier bus.

## Architecture et validation

Le JSFX utilise moins de 43 000 cellules de mémoire locale, toutes initialisées au chargement. Les voix et les files utilisent une liste libre, sans allocation par note. Quantize emploie une table de 128 résultats recalculée uniquement lors d'un changement de sélection ou de Tie Break. Relative parcourt au plus 128 candidates dans le sens du déplacement ; son curseur et sa dernière entrée sont mémorisés par canal, indépendamment des voix libérées. `stop_voice_output` retire seulement la propriété MIDI, tandis que `finish_voice` libère aussi l'enregistrement d'entrée. L'interface ne modifie jamais les voix et n'envoie aucun MIDI ; seul `@block` le fait.

Les tests exécutent **le code du fichier JSFX**, dans le moteur EEL2 natif officiel de Cockos/WDL, avec adaptation des seules fonctions hôtes de MIDI et de sliders. Ils compilent et exécutent également le véritable `@gfx` avec le moteur graphique LICE, sans fenêtre.

```powershell
python "jsfx/tests/test_midi_smart_quantizer.py" --eel "C:/chemin/WDL/WDL/eel2/loose_eel.exe"
# Avec rendus PPM de l'interface :
python "jsfx/tests/test_midi_smart_quantizer.py" --eel "C:/chemin/loose_eel.exe" --render "$env:TEMP/quantizer-previews"
```

Pour construire `loose_eel.exe` sur Windows : cloner [WDL](https://github.com/justinfrankel/WDL), ouvrir une invite de développement MSVC x64, se placer dans `WDL/eel2` puis lancer `nmake /f makefile.vc x64=1`. Le moteur et ses fichiers de compilation ne sont pas des dépendances du plugin.

La suite couvre les douze situations demandées, les vélocités et offsets, les deux directions d'égalité, les collisions, les répétitions FIFO, les 16 canaux, le mapping, l'aftertouch, la sélection vide, les limites MIDI, les contrôleurs de sécurité, les relâchements tardifs après Panic, la saturation à 4 096 voix, les clics du clavier graphique et une séquence déterministe de 1 800 événements. Chaque scénario vérifie aussi l'absence de voix ou de propriétaires restants. Le récepteur de test refuse tout Note On de sortie déjà actif et tout Note Off sans Note On correspondant.

Résultat du 21 octobre 2026 : **0 échec / 1 972 979 assertions** dans WDL/EEL2. Les tests vérifient notamment les variantes Base et Last note, la coupure anticipée de la base avant le Note On relatif, son relâchement et son aftertouch tardifs sans effet sur une nouvelle sortie, la mémoire Last note sans chevauchement des touches, les états séparés par canal, les basculements de référence et de sustain, le passage intact de CC64 en Thru et son interception en Capture. Les interfaces Base, Last note, Mapping et Quantize redimensionné sont rendues avec les fonctions graphiques natives.

Un second test charge le fichier JSFX non modifié dans le **véritable hôte REAPER**, entre un générateur MIDI et un vérificateur, via le convertisseur batch. Il utilise une instance cachée, un dossier de ressources temporaire et un WAV de contrôle, sans ouvrir de projet utilisateur :

```powershell
python "jsfx/tests/test_reaper_host.py" --reaper "C:/chemin/REAPER/reaper.exe"
```

Validé avec **REAPER 7.82 x64 sous Windows** dans les quatre combinaisons **Base/Last note × Thru/Capture** : chargement du plugin et des sliders, suite de chaque variante, Note Off de la base avant le premier Note On relatif, nouvelle attaque lors du retour à sa hauteur, mémoire après relâchement, absence de second Note Off lors du relâchement physique de la base, offsets, vélocités, reprise après All Notes Off et passage/interception de CC64. Le test réutilise les caches de scan de l'installation portable voisine pour éviter un scan des instruments tiers. Selon les restrictions d'exécution de l'environnement, le lancement et la fermeture de cette instance peuvent nécessiter une exécution hors du bac à sable. L'écoute avec un clavier matériel et votre instrument virtuel reste à effectuer dans votre configuration audio.

Références techniques : [MIDI et bus JSFX](https://www.reaper.fm/sdk/js/midi.php), [cycle de vie JSFX](https://www.reaper.fm/sdk/js/js.php), [paramètres et notifications à l'hôte](https://www.reaper.fm/sdk/js/advfunc.php), [graphisme natif](https://www.reaper.fm/sdk/js/gfx.php).
