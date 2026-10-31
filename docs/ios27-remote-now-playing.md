# iOS 27 remote Now Playing sessions: field notes

[English](#english) · [Français](#français)

## English

iOS 27 lets an app show a media player it does not run itself (a music server, a speaker, a TV) on the iPhone's Now
Playing surfaces: Control Center, the Lock Screen and the Dynamic Island. The app starts a *remote media session*
(`RemoteMediaSession`, `NowPlaying` framework) with a set of attributes; the system hands those attributes to an
extension of the app (extension point `com.apple.nowplaying.remote-media`, protocol `RemoteMediaSessionExtension`),
which builds the card and receives the user's commands. Push notifications can start, update and end the session while
the app is closed.

These notes come from building [Platine](../README.md), a card for an OwnTone music server, on an iPhone running
iOS 27.x (27.2 for the last tests), with builds installed from Xcode and the development APNs environment, in
October 2026. Documentation was thin at the time; everything below was observed on a real device. Each finding about
iOS says whether it was **established** (reproduced, or checked in the system log) or only **observed** once or a few
times; the other points are design advice drawn from them.

### 1. Networking from the extension

- **Established: the extension cannot reach the local network,** even when the app itself has been granted local
  network access. Connections to LAN addresses are refused by NECP; `mediaremoted`'s log shows it applies a "Network
  restriction" to the extension.
- **Established: the Internet is allowed,** including a public address that leads back home (the router's NAT loopback
  sent it to the server) and a Tailscale address (`*.ts.net`).
- **Consequence:** give the extension a public HTTPS endpoint in front of the server, with a token and an allowlist.
  Platine uses a small Caddy "gatekeeper" behind the server's reverse proxy; the app goes through it too, so there is
  one path at home and away, and the app no longer needs local network permission.

### 2. Push notifications

- **Established: push type and topic.** Header `apns-push-type: nowplaying`, topic `<app bundle id>.push-type.nowplaying`,
  token-based authentication (ES256 JWT, refreshed every 50 minutes in Platine). Payload:

  ```json
  {"aps": {"event": "start", "timestamp": 1793440000, "attributes": {"id": "…", "…": "…"}}}
  ```

  `event` is `start`, `update` or `end`; `attributes` is your `RemoteMediaSessionAttributes` type, encoded as JSON.
- **Established: dates must be numbers.** An attribute holding a date as an ISO 8601 string (as in Apple's example) gets
  the push rejected without waking the extension, and nothing tells you why. Seconds since 1970 as a number work:
  declare timestamps as `TimeInterval`, not `Date`.
- **Established: push-to-start works with the app closed.** The app needs the `aps-environment` entitlement; without it
  `RemoteMediaSession.pushToStartToken` stays empty. Follow `pushToStartTokenUpdates` and send each token to your
  server. A `start` push wakes the extension through `mediaremoted`, and the card appears in Control Center.
- **Established: each session has its own update token,** delivered to the extension (`pushToken`, `pushTokenUpdates`),
  also for a session the app started itself. A new session gets a new token. The token reached the server 0.6 to
  5 seconds after the `start` push.
- **Established: `end` works with attributes reduced to the session id.** The card disappears; iOS shows its empty
  player ("Not Playing") instead.
- **Playback progress needs no push:** the system extrapolates from the position and its timestamp. Push on a seek.
- **Group events.** A volume slider produces bursts of events: Platine waits for one second of quiet (five seconds at
  most) and pushes the last state only. With that, a slider dragged on the card itself does not jump back while the user
  is moving it. Siri changes the volume in steps spread over a few seconds, which can still give two pushes.
- **No documented quota** for this push type. Platine sends everything at priority 10 and logs any refusal (HTTP 429).
- **Gotcha (Go):** the device token is part of the request path, so `net/http` client errors (`*url.Error`) contain the
  whole token. Log only the underlying cause.

### 3. The extension's lifecycle

- **Established: `mediaremoted` keeps the extension's process alive and reuses it after the app is reinstalled.** The old
  code keeps answering. Platine records the modification date of its executable when the process starts and calls
  `exit(0)` when a session is requested or updated and that date has changed or the file is gone; iOS launches the new
  build on the next call. Read the date through `FileManager.attributesOfItem`, not a cached `URL` resource value, and
  record it at process launch: a lazy `static let` would only capture it at first use.
- **Observed: change `CFBundleVersion` on every build,** or iOS may keep using the previous extension for a while.
- **Observed: the extension is called two to four times for the same session** (several `session(_:)` calls). Make
  anything it reports to your server idempotent.
- **Observed: iOS suspends the extension soon after it returns.** Finish network work before returning, and retry token
  delivery a few times (Platine: right away, then after 2, 10 and 30 seconds).

### 4. Lock Screen and Control Center

- **Observed: iOS decides who owns the Lock Screen, and we found no reliable trigger.** On the bench, a card started by
  push while the app was closed appeared in Control Center only, and moved to the Lock Screen and the Dynamic Island once
  the user touched it there (twice). A `start` push received while the app was open went straight to the Lock Screen
  (once). In an earlier test, though, touching the card or playing and pausing from it changed nothing, and later that
  day the card took the Lock Screen on its own, with no trigger we could identify. Once promoted, the card kept its
  place for as long as the session lived.
- **Established: `requestToBecomeSystemPrimary` does not force it.** Called with the app in the foreground, it is
  accepted (`mediaremoted` logs "set active session"), but the Lock Screen keeps the endpoint iOS selected
  (`ProactiveSystemEndpoint remains … selectionReason = UserSelected`). Once, with no active speaker, it failed
  (`internalFailure`).
- **Observed: a competing tile is not the cause.** OwnTone reports Now Playing to HomePods through MediaRemote, which
  gives them their own native tile on the iPhone. With that turned off (a setting proposed upstream in
  owntone/owntone-server#2064, from a patched build at the time of writing), the native tile was gone and the card still
  needed the user's touch (once).
- **Hypothesis:** promotion belongs to the session. Every new session asked for the touch again; keeping one session
  alive across listening sessions might keep the place.

### 5. Devices on the card

- `MediaDevice` rows with an `absoluteVolume` capability give one volume slider per speaker; they work well for AirPlay
  speakers driven by the server.
- **There is no HomePod device type.** `speakerGroup` exists from iOS 27.2 and shows a "two speakers" icon; Platine uses
  it for a stereo pair, which the server sees as two outputs and the card shows as one row whose slider sets both.
- **Observed: iOS orders the device rows itself,** alphabetically as far as we saw: renaming the stereo-pair row moved
  it to its alphabetical place, whatever order the extension gave.

### 6. Debugging on the device

- **Write your own log into the App Group container, under `Library/`.** `devicectl` refuses the container's root:
  `xcrun devicectl device copy from --device <udid> --domain-type appGroupDataContainer --domain-identifier <group> --source Library/<file> --destination <file>`.
- **Rejections that never reach your code** (a push refused before the extension wakes, the network restriction) show
  in the system log only: `idevicesyslog -p mediaremoted` (libimobiledevice) on the Mac, with the iPhone unlocked; add
  `-n` (`--network`) for an iPhone reached over Wi-Fi rather than USB.

### 7. Server-side notes

- OwnTone's websocket (`notify` protocol, port 3688) says *that* something changed; read the state back from the JSON
  API. Filter the queue on the current item (`/api/queue?id=<item>`): the whole queue can be thousands of tracks.
- Keep the push tokens across restarts, forget a token APNs refuses, and ignore the token of a session you have ended:
  the extension may hand it again, and taking it back would reopen a finished card (update, end two minutes later, and
  so on).
- An extension that hands its token on every wake-up, and a server that pushes on every new token, make a loop: a token
  received for an open session must not trigger a push by itself.

## Français

iOS 27 permet à une app d'afficher un lecteur qu'elle ne fait pas tourner elle-même (un serveur de musique, une enceinte,
un téléviseur) dans les écrans « À l'écoute » de l'iPhone : Centre de contrôle, écran verrouillé et Dynamic Island.
L'app démarre une *session distante* (`RemoteMediaSession`, framework `NowPlaying`) avec des attributs ; le système les
remet à une extension de l'app (point d'extension `com.apple.nowplaying.remote-media`, protocole
`RemoteMediaSessionExtension`), qui construit la carte et reçoit les commandes de l'utilisateur. Des notifications push
peuvent démarrer, mettre à jour et terminer la session app fermée.

Ces notes viennent de la construction de [Platine](../README.md), une carte pour un serveur de musique OwnTone, sur un
iPhone sous iOS 27.x (27.2 pour les derniers essais), avec des versions installées par Xcode et l'environnement APNs de
développement, en octobre 2026. La documentation était mince à ce moment-là ; tout ce qui suit a été observé sur un
appareil réel. Chaque constat sur iOS dit s'il est **établi** (reproduit, ou vérifié dans le journal système) ou
seulement **observé** une ou quelques fois ; les autres points sont des conseils de conception qui en découlent.

### 1. Le réseau depuis l'extension

- **Établi : l'extension ne peut pas joindre le réseau local,** même quand l'app a reçu l'autorisation d'accès au réseau
  local. Les connexions vers des adresses locales sont refusées par NECP ; le journal de `mediaremoted` montre qu'il
  applique une « Network restriction » à l'extension.
- **Établi : Internet est permis,** y compris une adresse publique qui ramène à la maison (le NAT loopback de la box
  l'envoyait au serveur) et une adresse Tailscale (`*.ts.net`).
- **Conséquence :** donner à l'extension un point d'entrée HTTPS public devant le serveur, avec un jeton et une liste
  blanche. Platine utilise un petit « portier » Caddy derrière le proxy inversé du serveur ; l'app passe aussi par lui :
  un seul chemin, à la maison comme dehors, et l'app n'a plus besoin de l'accès au réseau local.

### 2. Les notifications push

- **Établi : type et sujet des push.** En-tête `apns-push-type: nowplaying`, sujet `<identifiant de l'app>.push-type.nowplaying`,
  authentification par jeton (JWT ES256, renouvelé toutes les 50 minutes dans Platine). Corps :

  ```json
  {"aps": {"event": "start", "timestamp": 1793440000, "attributes": {"id": "…", "…": "…"}}}
  ```

  `event` vaut `start`, `update` ou `end` ; `attributes` est votre type `RemoteMediaSessionAttributes`, encodé en JSON.
- **Établi : les dates doivent être des nombres.** Un attribut qui porte une date en texte ISO 8601 (comme dans l'exemple
  d'Apple) fait rejeter la push sans réveiller l'extension, et rien ne dit pourquoi. Un nombre de secondes depuis 1970
  passe : déclarer les horodatages en `TimeInterval`, pas en `Date`.
- **Établi : le démarrage par push marche app fermée.** L'app a besoin du droit `aps-environment` ; sans lui,
  `RemoteMediaSession.pushToStartToken` reste vide. Suivre `pushToStartTokenUpdates` et envoyer chaque jeton à votre
  serveur. Une push `start` réveille l'extension par `mediaremoted`, et la carte apparaît dans le Centre de contrôle.
- **Établi : chaque session a son propre jeton de mise à jour,** remis à l'extension (`pushToken`, `pushTokenUpdates`),
  aussi pour une session démarrée par l'app. Une nouvelle session reçoit un nouveau jeton. Le jeton est arrivé au serveur
  0,6 à 5 secondes après la push `start`.
- **Établi : `end` marche avec des attributs réduits à l'identifiant de la session.** La carte disparaît ; iOS affiche à
  la place son lecteur vide (« À l'arrêt »).
- **L'avancement dans le morceau n'a besoin d'aucune push :** le système l'extrapole à partir de la position et de son
  horodatage. Envoyer une push sur un saut dans le morceau.
- **Regrouper les événements.** Un curseur de volume produit des rafales d'événements : Platine attend une seconde de
  calme (cinq secondes au plus) et n'envoie que le dernier état. Ainsi, un curseur glissé sur la carte elle-même ne
  revient pas en arrière pendant le geste. Siri règle le volume par paliers étalés sur quelques secondes, ce qui peut
  encore donner deux push.
- **Aucun quota documenté** pour ce type de push. Platine envoie tout en priorité 10 et journalise tout refus (HTTP 429).
- **Piège (Go) :** le jeton de l'appareil fait partie du chemin de la requête, donc les erreurs du client `net/http`
  (`*url.Error`) contiennent le jeton entier. Ne journaliser que la cause.

### 3. La vie de l'extension

- **Établi : `mediaremoted` garde le processus de l'extension et le réutilise après une réinstallation de l'app.** L'ancien
  code continue de répondre. Platine relève la date de modification de son exécutable au lancement du processus, et
  appelle `exit(0)` quand une session est demandée ou mise à jour et que cette date a changé ou que le fichier a
  disparu ; iOS lance la nouvelle version à l'appel suivant. Lire la date par `FileManager.attributesOfItem`, pas par
  une valeur de ressource d'`URL` gardée en cache, et la relever au lancement du processus : un `static let` paresseux
  ne la prendrait qu'au premier usage.
- **Observé : changer `CFBundleVersion` à chaque compilation,** sinon iOS peut garder un moment l'extension précédente.
- **Observé : l'extension est appelée deux à quatre fois pour la même session** (plusieurs appels de `session(_:)`).
  Rendre idempotent tout ce qu'elle signale à votre serveur.
- **Observé : iOS suspend l'extension peu après qu'elle a rendu la main.** Finir le travail réseau avant de rendre la
  main, et retenter quelques fois l'envoi des jetons (Platine : aussitôt, puis après 2, 10 et 30 secondes).

### 4. Écran verrouillé et Centre de contrôle

- **Observé : iOS décide qui occupe l'écran verrouillé, et nous n'avons trouvé aucun déclencheur sûr.** Au banc, une
  carte démarrée par push app fermée n'est apparue que dans le Centre de contrôle, et elle est passée sur l'écran
  verrouillé et dans la Dynamic Island dès que l'utilisateur l'y a touchée (deux fois). Une push `start` reçue app
  ouverte est allée droit sur l'écran verrouillé (une fois). Lors d'un essai antérieur pourtant, toucher la carte ou y
  faire lecture et pause n'a rien changé, et plus tard ce jour-là la carte a pris l'écran verrouillé d'elle-même, sans
  déclencheur identifié. Une fois promue, la carte a gardé sa place tant que la session vivait.
- **Établi : `requestToBecomeSystemPrimary` ne force rien.** Appelé app au premier plan, il est accepté (`mediaremoted`
  journalise « set active session »), mais l'écran verrouillé garde le point de lecture choisi par iOS
  (`ProactiveSystemEndpoint remains … selectionReason = UserSelected`). Une fois, sans aucune enceinte active, il a
  échoué (`internalFailure`).
- **Observé : une tuile concurrente n'en est pas la cause.** OwnTone signale ce qu'il joue aux HomePod par MediaRemote,
  ce qui leur donne leur propre tuile native sur l'iPhone. Une fois cela coupé (réglage proposé au projet dans
  owntone/owntone-server#2064, tiré d'une version modifiée au moment de l'écriture), la tuile native avait disparu, et
  la carte a encore eu besoin du toucher de l'utilisateur (une fois).
- **Hypothèse :** la promotion appartient à la session. Chaque nouvelle session a redemandé le toucher ; garder une même
  session d'une écoute à l'autre garderait peut-être la place.

### 5. Les appareils de la carte

- Des lignes `MediaDevice` dotées de la capacité `absoluteVolume` donnent un curseur de volume par enceinte ; elles
  marchent bien pour des enceintes AirPlay pilotées par le serveur.
- **Aucun type d'appareil HomePod.** `speakerGroup` existe à partir d'iOS 27.2 et montre une icône « deux enceintes » ;
  Platine s'en sert pour une paire stéréo, que le serveur voit comme deux sorties et que la carte montre en une seule
  ligne, dont le curseur règle les deux.
- **Observé : iOS range lui-même les lignes des appareils,** par ordre alphabétique d'après nos essais : renommer la
  ligne de la paire stéréo l'a déplacée à sa place alphabétique, quel que soit l'ordre donné par l'extension.

### 6. Déboguer sur l'appareil

- **Écrire son propre journal dans le conteneur App Group, sous `Library/`.** `devicectl` refuse la racine du conteneur :
  `xcrun devicectl device copy from --device <udid> --domain-type appGroupDataContainer --domain-identifier <groupe> --source Library/<fichier> --destination <fichier>`.
- **Les refus qui n'atteignent jamais votre code** (une push rejetée avant le réveil de l'extension, la restriction
  réseau) n'apparaissent que dans le journal système : `idevicesyslog -p mediaremoted` (libimobiledevice) sur le Mac,
  iPhone déverrouillé ; ajouter `-n` (`--network`) pour un iPhone joint en Wi-Fi plutôt qu'en USB.

### 7. Côté serveur

- La websocket d'OwnTone (protocole `notify`, port 3688) dit *qu'*une chose a changé ; relire l'état par l'API JSON.
  Filtrer la file sur l'élément en cours (`/api/queue?id=<élément>`) : la file entière peut compter des milliers de
  morceaux.
- Garder les jetons push d'un redémarrage à l'autre, oublier un jeton refusé par APNs, et ignorer le jeton d'une session
  qu'on a terminée : l'extension peut le redonner, et le reprendre rouvrirait une carte finie (update, end deux minutes
  plus tard, et ainsi de suite).
- Une extension qui redonne son jeton à chaque réveil, et un serveur qui envoie une push à chaque nouveau jeton, font
  une boucle : un jeton reçu pour une session ouverte ne doit déclencher aucune push à lui seul.
