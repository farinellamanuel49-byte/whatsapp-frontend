Pod::Spec.new do |s|
  s.name             = 'music_injector'
  s.version          = '0.1.0'
  s.summary          = 'Inject tracks into iOS Music library via idevice services'
  s.description      = <<-DESC
Injects audio files and playlists into the iOS Music library using the
device's own services (usbmuxd/lockdownd/AFC) through jkcoxson's idevice
Rust library compiled as a static lib.
                       DESC
  s.homepage         = 'https://github.com/farinellamanuel49-byte/whatsapp-frontend'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Devin' => 'devin@cognition.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,swift}'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.libraries        = 'sqlite3', 'z'
  s.xcconfig = {
    'LIBRARY_SEARCH_PATHS' => '"$(PODS_ROOT)/../../plugins/music_injector/ios/lib" "$(inherited)"',
    'OTHER_LDFLAGS' => '"-lidevice_ffi" "$(inherited)"',
    'HEADER_SEARCH_PATHS' => '"$(PODS_ROOT)/../../plugins/music_injector/ios/Classes" "$(inherited)"',
  }

  # Compila libidevice_ffi per iOS (aarch64 device + simulator)
  # richiedendo clang, rustup e la toolchain iOS.
  s.prepare_command = <<-CMD
    set -e
    if [ ! -f ios/lib/libidevice_ffi.a ]; then
      echo "Building idevice-ffi for iOS..."
      # Installa Rust se manca (runner CI non ce l'ha)
      if ! command -v cargo >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
      fi
      export PATH="$HOME/.cargo/bin:$PATH"
      IDEVICE_DIR="$(mktemp -d)"
      git clone --depth 1 https://github.com/jkcoxson/idevice.git "$IDEVICE_DIR/src"
      rustup target add aarch64-apple-ios aarch64-apple-ios-sim
      (cd "$IDEVICE_DIR/src/ffi" && \\
        cargo build --release --locked \\
          --target aarch64-apple-ios \\
          --no-default-features \\
          --features "ring,afc,usbmuxd,pair,house_arrest,remote_pairing,rsd,tcp")
      mkdir -p ios/lib
      cp "$IDEVICE_DIR/src/target/aarch64-apple-ios/release/libidevice_ffi.a" ios/lib/
      cp "$IDEVICE_DIR/src/target/aarch64-apple-ios/release/build/idevice-ffi-*/out/idevice.h" ios/Classes/ 2>/dev/null || true
      echo "IDEVICE_DIR=$IDEVICE_DIR" > /tmp/idevice_dir.env
    fi
  CMD
end
