import "dart:ui";

class ChangeLogStrings {
  final String title;
  final String description;

  const ChangeLogStrings({required this.title, required this.description});

  static ChangeLogStrings forLocale(Locale locale) {
    final key = locale.countryCode != null && locale.countryCode!.isNotEmpty
        ? "${locale.languageCode}_${locale.countryCode}"
        : locale.languageCode;

    return _translations[key] ??
        _translations[locale.languageCode] ??
        _translations["en"]!;
  }

  static const Map<String, ChangeLogStrings> _translations = {
    "en": ChangeLogStrings(
      title: "Document scanner",
      description:
          "Locker can now scan paper documents. Point the camera at a page and save it as a PDF, straight into the collection you pick.",
    ),
  };
}
