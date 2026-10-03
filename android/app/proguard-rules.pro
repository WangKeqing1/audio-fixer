# ML Kit discovers these four registrars by their manifest names and invokes
# their no-argument constructors reflectively. The optimized AGP 9.1 APK kept
# their class names but removed every constructor, leaving an empty component
# graph and causing LanguageIdentification.getClient() to throw.
# Keep only the actual discovery roots, not the whole SDK or application.
-keep class com.google.mlkit.common.internal.CommonComponentRegistrar { *; }
-keep class com.google.mlkit.nl.languageid.internal.LanguageIdRegistrar { *; }
-keep class com.google.mlkit.nl.languageid.bundled.internal.ThickLanguageIdRegistrar { *; }
-keep class com.google.mlkit.nl.translate.NaturalLanguageTranslateRegistrar { *; }

# Preserve the bundled identifier's JNI entry points and native-facing members.
# This is the class actually packaged by language-id 17.0.6. Google's Language
# ID shrinker guidance: https://developers.google.com/ml-kit/known-issues
-keep class com.google.mlkit.nl.languageid.bundled.internal.ThickLanguageIdentifier { *; }
