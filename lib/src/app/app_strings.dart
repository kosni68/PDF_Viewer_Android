abstract final class AppStrings {
  static const appName = 'Lecteur PDF';
  static const libraryTitle = 'Bibliotheque PDF';
  static const librarySubtitle =
      'Ouvrez, recherchez et reprenez vos PDF locaux sans connexion.';
  static const openPdf = 'Ouvrir un PDF';
  static const scanDocument = 'Scanner un document';
  static const emptyTitle = 'Aucun document';
  static const emptyBody =
      'Choisissez un fichier PDF depuis votre appareil pour commencer.';
  static const favoritesOnly = 'Favoris seulement';
  static const favoritesSection = 'Favoris';
  static const recentsSection = 'Recents';
  static const largeFileWarning =
      'Ce fichier depasse 250 Mo. Le chargement peut etre plus lent.';
  static const unavailableDocument = 'Le document n est plus accessible.';
  static const pickFailed = 'Impossible d ouvrir ce document.';
  static const readerLoading = 'Chargement du document...';
  static const searchHint = 'Rechercher dans le PDF';
  static const searchNoResult = 'Aucun resultat';
  static const searchProgress = 'Recherche en cours...';
  static const documentNotFoundTitle = 'Document introuvable';
  static const documentNotFoundBody =
      'Le fichier n est plus disponible et a ete retire de la bibliotheque.';
  static const unreadableTitle = 'Lecture impossible';
  static const unreadableBody = 'Le PDF est corrompu, protege ou non lisible.';
  static const retry = 'Reessayer';
  static const backToLibrary = 'Retour a la bibliotheque';
  static const addFavorite = 'Ajouter aux favoris';
  static const removeFavorite = 'Retirer des favoris';
  static const sharePdf = 'Partager le PDF';
  static const shareFailed = 'Impossible de partager ce document.';
  static const shareChooserTitle = 'Partager le PDF';
  static const unknownDocument = 'Document PDF';
  static const saveDocument = 'Enregistrer';
  static const scannerImportFailed = 'Impossible d importer cette image.';
  static const scannerSaveFailed = 'Impossible de creer ce PDF.';
  static const scannerPreviewFailed = 'Impossible d afficher cet apercu.';
  static const scannerEmptyTitle = 'Scannez un document';
  static const scannerEmptyBody =
      'Prenez une photo ou importez plusieurs images pour creer un PDF.';
  static const scanTakePhoto = 'Prendre une photo';
  static const scanImportImages = 'Importer des images';
  static const scanCrop = 'Rogner';
  static const scanCropTitle = 'Rognage';
  static const scanCropBody =
      'Ajustez la zone du document, lancez un cadrage auto avec redressement ou revenez au cadrage complet.';
  static const scanApplyCrop = 'Appliquer';
  static const scanCancelCrop = 'Annuler le rognage';
  static const scanAutoCrop = 'Auto cadrage';
  static const scanResetCrop = 'Cadrage complet';
  static const scanRectCropMode = 'Rectangle';
  static const scanCornerCropMode = '4 coins';
  static const scanCornerCropBody =
      'Deplacez chaque poignee pour aligner les quatre coins du document.';
  static const scanPerspectiveCorrectionActive = 'Redressement auto actif';
  static const scanRotateLeft = 'Rotation -90';
  static const scanRotateRight = 'Rotation +90';
  static const scanDeletePage = 'Supprimer';
  static const scanAdjustments = 'Retouches';
  static const scanBrightness = 'Luminosite';
  static const scanContrast = 'Contraste';
  static const scanFilter = 'Filtre';
  static const scanFilterNone = 'Aucun';
  static const scanFilterDocument = 'Document';
  static const scanFilterVivid = 'Vif';
  static const scanFilterWarm = 'Chaud';
  static const scanFilterCool = 'Froid';
  static const scanColorMode = 'Mode couleur';
  static const scanColorModeColor = 'Couleur';
  static const scanColorModeGrayscale = 'Gris';
  static const scanColorModeBlackWhite = 'Noir et blanc';
  static const scanQuality = 'Qualite PDF';
  static const scanQualityOriginal = 'Original';
  static const scanQualityOptimized = 'Optimise';
  static const scanQualityLight = 'Leger';
  static const scanReorderHint =
      'Maintenez une miniature pour reordonner les pages.';
  static const scannerAutoCropFailed =
      'Impossible de detecter ou redresser automatiquement ce document.';

  static String lastPage(int pageNumber) => 'Derniere page : $pageNumber';
  static String pageCount(int pageCount) => 'Pages : $pageCount';
  static String lastOpened(String date) => 'Ouvert le $date';
  static String searchResults(int current, int total) => '$current / $total';
  static String scanPageIndex(int pageNumber) => 'Page $pageNumber';
}
