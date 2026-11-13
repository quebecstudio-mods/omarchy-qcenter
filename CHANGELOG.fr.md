# Journal des versions

## 1.1.0 - 2026-11-12

### Ajouts

- **Une fenêtre de réglages**, dessinée avec les contrôles d'Omarchy : Apparence, Notifications, Hors du centre, Apps des sites, Agenda et À propos. Elle s'ouvre depuis l'engrenage en haut du centre, depuis le lanceur d'apps (Réglages de qCenter) ou avec `omarchy-shell -q quebecstudio.qcenter settings`. On y ajoute les calendriers, avec un lien masqué, et on choisit les apps des sites dans la liste du lanceur.
- **Quatre styles**, ceux de qDock : Omarchy, Cupertino, Redmond et Plasma.
- **Les confirmations restent hors du centre.** Les notifications d'urgence basse (capture enregistrée, disposition changée, copié dans le presse-papiers) s'affichent toujours en bulle mais ne s'accumulent plus dans le centre ; activez `lowUrgency` pour les garder.
- **Tenir des apps à l'écart** (`hiddenApps`) : leurs bulles s'affichent toujours, le centre les ignore.
- **Apps des sites** (`webApps`) : la notification d'un site ouvre son app web, ou l'app que vous lui avez choisie, plutôt que le navigateur.

### Changements

- **`style` `"mac"` devient `"cupertino"`** ; l'ancien nom est toujours lu. Cupertino reste le style par défaut.
- Une notification sans icône prend celle de son app dans le lanceur, sinon une cloche, au lieu de son initiale.

### Corrections

- Une notification d'une seule ligne n'est plus moins haute que son icône.

## 1.0.0 - 2026-11-11

Première version.
