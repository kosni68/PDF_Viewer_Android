# pdf_reader

Lecteur PDF Flutter pour Android.

## Fonctionnalités

- ouverture de PDF locaux depuis le sélecteur de fichiers Android
- lecture avec zoom et navigation
- recherche de texte dans le PDF
- favoris et récents
- reprise à la dernière page lue

## Prérequis

- Flutter installé
- Android Studio installé
- un émulateur Android configuré dans Android Studio

## Installation

Depuis la racine du projet :

```bash
flutter pub get
```

## Tester dans le simulateur Android Studio

### Depuis Android Studio

1. Ouvre le projet dans Android Studio.
2. Va dans `Tools > Device Manager`.
3. Démarre un émulateur Android avec le bouton `Play`.
4. Attends que l’émulateur soit complètement lancé.
5. Sélectionne cet émulateur dans la barre de périphériques.
6. Lance l’application avec `Run`.

### Depuis le terminal

Liste les émulateurs disponibles :

```bash
flutter emulators
```

Lance un émulateur :

```bash
flutter emulators --launch <emulator_id>
```

Exemple :

```bash
flutter emulators --launch Pixel_7a
```

Puis démarre l’application :

```bash
flutter run
```

## Commandes utiles

Analyse statique :

```bash
flutter analyze
```

Tests :

```bash
flutter test
```

Build APK debug :

```bash
flutter build apk --debug
```

## Notes

- Pendant `flutter run`, appuie sur `r` pour un hot reload.
- Appuie sur `R` pour un hot restart.
- Appuie sur `q` pour arrêter l’application.
