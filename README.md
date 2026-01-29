# Android 16KB Page Size Checker

Script Bash per verificare la conformità delle librerie native Android (.so) al requisito di **16KB page size** introdotto con Android 15.

## Perché è necessario?

A partire da **Android 15**, i dispositivi possono utilizzare page size di 16KB invece dei tradizionali 4KB. Le librerie native (.so) devono essere compilate con allineamento corretto per funzionare su questi dispositivi.

### Requisiti tecnici verificati:
- **p_align ≥ 16384** (16KB) per tutti i segmenti PT_LOAD
- **Congruenza**: `p_vaddr % p_align == p_offset % p_align`

## Requisiti

- **macOS** o **Linux**
- **Android NDK 27+** (contiene `llvm-readobj`)

## Installazione

```bash
chmod +x check-16kb.sh
```

## Utilizzo

### Modalità interattiva
```bash
./check-16kb.sh
```
Lo script chiederà il percorso NDK e il file da analizzare.

### Con parametri
```bash
# Singolo file .so
./check-16kb.sh /path/to/library.so

# Directory con file .so
./check-16kb.sh /path/to/libs/

# APK, AAR, AAB o ZIP
./check-16kb.sh app-release.apk

# Specificando il percorso NDK
./check-16kb.sh -n /path/to/ndk /path/to/file.apk
```

### Opzioni
| Opzione | Descrizione |
|---------|-------------|
| `-n, --ndk` | Percorso root dell'Android NDK |
| `-h, --help` | Mostra l'help |

## Output

### ✓ File conforme
```
  ✓ libexample.so
```

### ✗ File non conforme
```
  ✗ libexample.so
    Seg2: align=4096 (< 16384); 
```

## Exit codes

| Codice | Significato |
|--------|-------------|
| `0` | Tutti i file sono conformi |
| `1` | Uno o più file non conformi |

## Come correggere i file non conformi

### 1. Aggiorna l'NDK
Usa **NDK 27** o superiore.

### 2. Configura CMake (build.gradle)
```gradle
android {
    defaultConfig {
        externalNativeBuild {
            cmake {
                arguments "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
            }
        }
    }
}
```

### 3. Oppure aggiungi i linker flags manualmente
```gradle
android {
    defaultConfig {
        externalNativeBuild {
            cmake {
                cppFlags "-Wl,-z,max-page-size=16384"
            }
        }
    }
}
```

### 4. Per ndk-build (Android.mk)
```makefile
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384
```

## Librerie di terze parti

Se le librerie non conformi provengono da SDK di terze parti:
1. Contatta il fornitore richiedendo versioni 16KB-compatibili
2. Verifica se sono disponibili aggiornamenti

## Riferimenti

- [Android 16KB Page Size Documentation](https://developer.android.com/guide/practices/page-sizes)
- [NDK 27 Release Notes](https://developer.android.com/ndk/downloads/revision_history)

## License

GPL-3.0 license
