#!/bin/bash

echo "🧹 Cleaning Flutter build cache..."
cd /Users/iosemagno/Development/media_assets_utils/example
flutter clean

echo "🧹 Cleaning Gradle cache..."
cd android
./gradlew clean

echo "📦 Getting Flutter dependencies..."
cd ..
flutter pub get

echo "✅ Clean complete! Now rebuild and run your app."
echo ""
echo "Run: flutter run"

