abstract final class AppStrings {
  static const appName = 'Lecteur PDF';
  static const libraryTitle = 'Bibliothèque PDF';
  static const librarySubtitle = 'Ouvrez, recherchez et reprenez vos PDF locaux sans connexion.';
  static const openPdf = 'Ouvrir un PDF';
  static const emptyTitle = 'Aucun document';
  static const emptyBody = 'Choisissez un fichier PDF depuis votre appareil pour commencer.';
  static const favoritesOnly = 'Favoris seulement';
  static const favoritesSection = 'Favoris';
  static const recentsSection = 'Récents';
  static const largeFileWarning = 'Ce fichier dépasse 250 Mo. Le chargement peut être plus lent.';
  static const unavailableDocument = 'Le document n’est plus accessible.';
  static const pickFailed = 'Impossible d’ouvrir ce document.';
  static const readerLoading = 'Chargement du document…';
  static const searchHint = 'Rechercher dans le PDF';
  static const searchNoResult = 'Aucun résultat';
  static const searchProgress = 'Recherche en cours…';
  static const documentNotFoundTitle = 'Document introuvable';
  static const documentNotFoundBody = 'Le fichier n’est plus disponible et a été retiré de la bibliothèque.';
  static const unreadableTitle = 'Lecture impossible';
  static const unreadableBody = 'Le PDF est corrompu, protégé ou non lisible.';
  static const retry = 'Réessayer';
  static const backToLibrary = 'Retour à la bibliothèque';
  static const addFavorite = 'Ajouter aux favoris';
  static const removeFavorite = 'Retirer des favoris';
  static const unknownDocument = 'Document PDF';

  static String lastPage(int pageNumber) => 'Dernière page : $pageNumber';
  static String pageCount(int pageCount) => 'Pages : $pageCount';
  static String lastOpened(String date) => 'Ouvert le $date';
  static String searchResults(int current, int total) => '$current / $total';
}
