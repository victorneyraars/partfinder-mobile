import os

# 1. Modificar AndroidManifest.xml
manifest_path = "android/app/src/main/AndroidManifest.xml"
if os.path.exists(manifest_path):
    with open(manifest_path, "r") as f:
        content = f.read()
    
    if "android.permission.INTERNET" not in content:
        content = content.replace("<application", '<uses-permission android:name="android.permission.INTERNET"/>\n    <application android:usesCleartextTraffic="true"')
    else:
        content = content.replace('android:usesCleartextTraffic="true"', "")
        content = content.replace("<application", '<application android:usesCleartextTraffic="true"')
        
    with open(manifest_path, "w") as f:
        f.write(content)
    print("AndroidManifest.xml actualizado correctamente.")

# 2. Modificar build.gradle para la firma
gradle_path = "android/app/build.gradle"
if os.path.exists(gradle_path):
    with open(gradle_path, "r") as f:
        content = f.read()

    signing_config = """
    signingConfigs {
        release {
            storeFile file("release.keystore")
            storePassword "partfinder123"
            keyAlias "partfinder"
            keyPassword "partfinder123"
        }
    }
    """
    
    if "signingConfigs {" not in content:
        content = content.replace("buildTypes {", signing_config + "\n    buildTypes {")
    
    content = content.replace("signingConfig signingConfigs.debug", "signingConfig signingConfigs.release")
    
    with open(gradle_path, "w") as f:
        f.write(content)
    print("build.gradle actualizado correctamente.")
