import os
import re

# Configurar signing en build.gradle
gradle_path = 'android/app/build.gradle'
if os.path.exists(gradle_path):
    with open(gradle_path, 'r') as f:
        content = f.read()

    signing_block = '''
    signingConfigs {
        release {
            keyAlias 'partfinder-key'
            keyPassword 'partfinder2026'
            storeFile file('upload-keystore.jks')
            storePassword 'partfinder2026'
        }
    }
'''
    # ===== Google Play: orientar a API 36 (compile + target) =====
    content = re.sub(r'compileSdkVersion\s+flutter\.compileSdkVersion', 'compileSdkVersion 36', content)
    content = re.sub(r'targetSdkVersion\s+flutter\.targetSdkVersion', 'targetSdkVersion 36', content)
    content = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 36', content)
    content = re.sub(r'targetSdk\s*=\s*flutter\.targetSdkVersion', 'targetSdk = 36', content)

    if 'partfinder-key' not in content:
        content = re.sub(r'android\s*\{', 'android {\n' + signing_block, content, count=1)
        content = re.sub(r'signingConfig\s*=?\s*signingConfigs\.debug', 'signingConfig signingConfigs.release', content)
        
    # Forzar minSdkVersion 21 para soporte de WebView moderno
    if 'minSdkVersion' in content:
        content = re.sub(r'minSdkVersion\s+.*', 'minSdkVersion 21', content)

        with open(gradle_path, 'w') as f:
            f.write(content)
    print(">>> build.gradle configurado con keystore permanente.")

# Configurar permisos y esquemas web en AndroidManifest.xml
manifest_path = 'android/app/src/main/AndroidManifest.xml'
if os.path.exists(manifest_path):
    with open(manifest_path, 'r') as f:
        m = f.read()

    queries = '<queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="http"/></intent><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent></queries>'
    perms = '<uses-permission android:name="android.permission.INTERNET"/>'

    if perms not in m:
        m = m.replace('<application', f'{perms}\n    {queries}\n    <application android:usesCleartextTraffic="true"')
        with open(manifest_path, 'w') as f:
            f.write(m)

    # Forzar aceleración por hardware (evita fallos de composición del WebView).
    if 'android:hardwareAccelerated="true"' not in m:
        m = m.replace('<application', '<application android:hardwareAccelerated="true"', 1)
        with open(manifest_path, 'w') as f:
            f.write(m)

    print(">>> AndroidManifest.xml configurado con queries, permisos y hardwareAccelerated.")
