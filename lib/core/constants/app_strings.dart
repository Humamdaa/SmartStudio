class AppStrings {
  AppStrings._();

  static const String appName    = 'PixMind';
  static const String appTagline = 'Smart Gallery Studio';
  static const String version    = 'v1.0.0';

  // Home tabs
  static const String all     = 'All';
  static const String photos  = 'Photos';
  static const String videos  = 'Videos';
  static const String folders = 'Albums';

  // Bottom Nav
  static const String home        = 'Home';
  static const String search      = 'Search';
  static const String albums      = 'Albums';
  static const String suggestions = 'Suggestions';

  // Permissions
  static const String permissionsTitle    = 'We need a few permissions';
  static const String permissionsSubtitle = 'To unlock all PixMind features';
  static const String permPhotos   = 'Photos & Videos';
  static const String permPhotosSub = 'Access your device gallery';
  static const String permMic      = 'Microphone';
  static const String permMicSub   = 'For voice search';
  static const String permBio      = 'Biometrics';
  static const String permBioSub   = 'Protect your secure folder';
  static const String allowBtn     = 'Allow & Continue';
  static const String skipBtn      = 'Skip for now';

  // Permission denied
  static const String permDeniedTitle   = 'No access to photos';
  static const String permDeniedBody    =
      'It looks like photo access was revoked.\nPlease enable it in app settings.';
  static const String openSettings  = 'Open Settings';
  static const String checkAgain    = 'Check again';

  // Search
  static const String searchHint    = 'Search by text, image, color or voice...';
  static const String noResults     = 'No results found';
  static const String tryDifferent  = 'Try different keywords or change search type';
  static const String generalSearch = 'General';
  static const String preciseSearch = 'Precise';
  static const String searchText    = 'Text';
  static const String searchImage   = 'Image';
  static const String searchColor   = 'Color';
  static const String searchVoice   = 'Voice';
  static const String searchOcr     = 'OCR';

  // Albums
  static const String smartAlbums    = 'Smart Albums';
  static const String people         = 'People';
  static const String findDuplicates = 'Find Duplicates';
  static const String newAlbum       = 'New Album';
  static const String items          = 'items';

  // Secure Folder
  static const String secureFolder = 'Secure Folder';
  static const String useBiometric = 'Use Fingerprint';
  static const String usePin       = 'Use PIN';
  static const String lockFolder   = 'Lock Folder';
  static const String addFiles     = 'Add Files';

  // Image Detail
  static const String aiCaption         = 'AI Caption';
  static const String extractedText     = 'Extracted Text';
  static const String sentimentAnalysis = 'Sentiment';
  static const String credibilityCheck  = 'Credibility Check';
  static const String imageInfo         = 'File Info';
  static const String edit              = 'Edit';
  static const String share             = 'Share';
  static const String moveToSecure      = 'Move to Secure';
  static const String delete            = 'Delete';

  // Loading
  static const String loadingPhotos  = 'Loading your photos...';
  static const String loadAllPhotos  = 'All photos loaded';
  static const String noPhotos       = 'No photos found';
  static const String pullToRefresh  = 'Pull to refresh';

  // Errors
  static const String errorGeneric    = 'Something went wrong. Please try again.';
  static const String errorPermission = 'Permission required to continue';
}
