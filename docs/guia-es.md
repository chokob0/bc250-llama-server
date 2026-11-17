# BC-250: guía de implantación y pruebas de llama-server (fork gfx1013)

> Guía personal de implantación (noviembre de 2026). Las IP (192.168.0.x) son las de mi red; cambia `192.168.0.104` por la de tu placa. Los pasos de copiar el tarball del fork se sustituyen ahora por `scripts/install.sh`.

## Antes de empezar

Esta guía sustituye Ollama por llama-server (fork llama.cpp-gfx1013) en la BC-250 y comprueba en cada fase que funciona antes de seguir. El objetivo es 80 tok/s o más en Qwen3.6-35B-A3B con poco contexto, y no toca kernel, drivers ni BIOS.

**Qué se instala y dónde:**

| Pieza | Ubicación | Sustituye a |
| --- | --- | --- |
| llama.cpp-gfx1013 (master b12363 + 4 parches Vulkan) | `/opt/llama.cpp` | El llama.cpp que trae Ollama |
| Modelos GGUF | `/models` | Los blobs de Ollama (que se quedan donde están) |
| Servicio `llama-server` en modo router, puerto 8080 | `/etc/systemd/system/llama-server.service`, `/etc/llama/` | `ollama.service`, puerto 11434 |
| Ajustes de Vulkan elegidos en la fase 5 | Variables `GGML_VK_*` en el servicio | — |

**Qué necesitas:**

- La BC-250 en el estado que dejamos: Fedora 43, kernel 6.18.9 fijado, Mesa 25.3.6, módulo amdgpu parcheado con 40 CU y `cyan-skillfish-governor-smu`.
- El fichero `llama.cpp-gfx1013-fork.tar.gz` que te envié en el chat, descargado en tu PC.
- Unos 35 GB libres en la BC-250: unos 30 GB para los cuatro modelos y el resto para la compilación.
- Acceso SSH desde el PC y una tarde. La prueba de resistencia final dura 30 minutos.

**Cómo usar esta guía:**

1. Haz las fases en orden. Cada una termina con una **comprobación**; si no se cumple, para y mira «Problemas frecuentes».
2. Apunta cada resultado en la «Hoja de resultados» del final. Si algo no cuadra, pégamela junto con el `resumen.txt` del benchmark.
3. Los comandos se ejecutan en la BC-250 salvo que se indique lo contrario. Define estas variables al abrir cada sesión:

   ```bash
   export M=/models/Qwen3.6-35B-A3B-UD-IQ2_M.gguf   # modelo principal
   export LL=/opt/llama.cpp                          # árbol del fork
   ```

**Contenido del paquete:**

| Fichero | Para qué |
| --- | --- |
| `patches/0001…0005-*.patch` | Los 5 commits del fork, para aplicar con `git am` |
| `llama.cpp-gfx1013.bundle` | Los mismos commits como bundle git (alternativa) |
| `bc250/build-fedora.sh` | Instala dependencias y compila |
| `bc250/bench-sweep.sh` | Benchmark A/B de los ajustes, con reloj y temperatura |
| `bc250/models.ini` | Presets de los modelos para el modo router |
| `bc250/llama-server.service` | Unidad systemd |
| `bc250/README.md`, `bc250/VERIFICACION.md` | Qué cambia el fork y qué está probado |

Lo que ya está verificado (sin la placa, con Vulkan por software): los parches compilan, se aplican limpios sobre master y los kernels modificados dan los mismos resultados que la CPU. Lo que falta, y para eso es esta guía: corrección y velocidad en la GPU real.

## Fase 0: copia de seguridad y línea base con Ollama

Antes de tocar nada, guarda tu configuración actual y mide lo que da Ollama hoy, para tener con qué comparar. Esta fase se hace con Ollama todavía funcionando.

**0.1 Guarda la configuración actual**

```bash
mkdir -p ~/backup-pre-llamacpp && cd ~/backup-pre-llamacpp
sudo cp -a /etc/systemd/system/ollama.service.d .            2>/dev/null
sudo cp -a /etc/cyan-skillfish-governor-smu .                2>/dev/null
sudo cp -a /etc/modprobe.d /etc/tmpfiles.d .
cat /proc/cmdline > cmdline.txt
ollama --version > versiones.txt; uname -r >> versiones.txt
rpm -q mesa-vulkan-drivers >> versiones.txt
ollama list > ollama-list.txt
```

Si tienes ya desplegado LiteLLM (Vía D), copia también su `litellm_config.yaml` desde el contenedor donde corre.

**0.2 Localiza el GGUF que ya tienes** (para no volver a descargar 11 GB):

```bash
ollama show --modelfile qwen3.6-35b-moe | grep '^FROM'
find / -xdev -name '*IQ2_M*.gguf' 2>/dev/null
```

Apunta la ruta. Si `FROM` apunta a un blob `sha256-…` de Ollama, ese blob es el GGUF tal cual y se puede copiar.

**0.3 Mide Ollama** (tres veces, anota la media):

```bash
for i in 1 2 3; do
  curl -s http://localhost:11434/api/generate -d '{
    "model": "qwen3.6-35b-moe", "think": false, "stream": false,
    "prompt": "Explica qué es SD-WAN en 300 palabras.",
    "options": {"num_predict": 400}}' \
  | jq '{tok_s: (.eval_count / .eval_duration * 1e9), prompt_tok_s: (.prompt_eval_count / .prompt_eval_duration * 1e9)}'
done
```

**0.4 (Opcional) Snapshot LVM del sistema.** El cambio no toca kernel ni drivers y la vuelta atrás es cambiar de servicio, así que no es imprescindible. Si lo haces, ten en cuenta lo que pasó con `root_pre40cu`: un snapshot se invalida cuando se llena, y copiar 30 GB de modelos lo llenaría. Hazlo después de la fase 3 o pon los modelos fuera del volumen raíz.

```bash
sudo vgs; sudo lvs                       # mira el nombre del VG/LV y el espacio libre
sudo lvcreate -s -L 15G -n root_pre_llamacpp /dev/<vg>/root
```

**Comprobación:** tienes la carpeta de backup, la ruta del GGUF y la velocidad de Ollama apuntada en la hoja de resultados (debería rondar los 42 tok/s que mediste en junio).

## Fase 1: preparar la placa

Esta fase deja la placa con toda la memoria libre, el reloj fijado a 1500 MHz y un monitor de reloj y temperatura, que es la condición en la que se midieron los 86,9 tok/s.

**1.1 Saca Ollama y reinicia.** Ollama se desactiva pero no se desinstala, para poder volver. Reiniciar es necesario porque Ollama 0.20 con Vulkan puede dejar retenida, hasta reiniciar, una cantidad de memoria parecida al tamaño del modelo que cargó.

```bash
sudo systemctl disable --now ollama
sudo systemctl reboot
```

**1.2 Comprueba el estado de la placa** tras el reinicio:

```bash
free -h                                              # MemAvailable > 14 GiB
swapon --show                                        # swap activo, en uso ~0
cat /sys/module/ttm/parameters/pages_limit           # 4194304
cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || grep -r bc250 /etc/modprobe.d/
sudo dnf install -y vulkan-tools jq
vulkaninfo --summary | grep -E 'deviceName|driverInfo'   # AMD BC-250 (RADV GFX1013), Mesa 25.3.x
systemctl is-active cyan-skillfish-governor-smu      # active
```

Si `bc250_cc_write_mode` no existe o no vale 3, el módulo cargado no es el parcheado (pasa si arrancó otro kernel) y la placa está en 24 CU: arréglalo antes de seguir.

Si el governor sale `inactive`, averigua por qué antes de seguir:

```bash
rpm -q cyan-skillfish-governor-smu                        # ¿está instalado?
systemctl is-enabled cyan-skillfish-governor-smu          # ¿arranca solo?
systemctl status cyan-skillfish-governor-smu --no-pager
journalctl -u cyan-skillfish-governor-smu -b -n 50 --no-pager
systemctl list-units --all | grep -i -E 'governor|oberon'  # no debe haber otro governor activo
```

- **No está instalado:** `sudo dnf copr enable filippor/bazzite && sudo dnf install cyan-skillfish-governor-smu`.
- **Instalado pero `disabled`:** no se activó al arranque. Ve primero al paso 1.4 y deja el máximo en 1500 MHz, porque tu configuración actual lo lleva a 2000.
- **`failed`:** el journal dice por qué; no lo actives hasta resolverlo.

En los tres casos, después del paso 1.4: arráncalo a mano con `sudo systemctl start cyan-skillfish-governor-smu`, revisa el journal y, si todo va bien, `sudo systemctl enable cyan-skillfish-governor-smu`. Usa un solo governor a la vez.

**1.3 Gobernador de CPU en `performance`** (con `schedutil` aparecen picos de latencia). Si la placa no expone `cpufreq`, sáltate este paso.

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo 'w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance' \
  | sudo tee /etc/tmpfiles.d/cpu-governor.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/cpu-governor.conf
```

**1.4 Reloj de la GPU a 1500 MHz para medir.** Ahora lo tienes a 2000 MHz, que en carga sostenida acaba en throttling. Abre la configuración y baja el punto más alto (frecuencia máxima o último `safe-point`) a 1500 MHz con 900 mV. Los nombres de las claves dependen de la versión del governor; usa los que ya tiene tu fichero.

```bash
sudoedit /etc/cyan-skillfish-governor-smu/config.toml
sudo systemctl restart cyan-skillfish-governor-smu
sudo journalctl -u cyan-skillfish-governor-smu -n 20 --no-pager
```

En la fase 5 probarás 1700 MHz; 2000 MHz solo si las temperaturas lo permiten.

**1.5 Monitor de reloj, temperatura y memoria.** Déjalo abierto en una segunda terminal durante todas las pruebas:

```bash
mkdir -p ~/bin && cat > ~/bin/bc250-mon <<'EOF'
#!/usr/bin/env bash
# Muestra cada segundo: reloj GPU, temperatura GPU, memoria disponible y swap usado.
while :; do
  clk=$(grep -h '\*' /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null | head -1 | awk '{print $2}')
  t=$(cat /sys/class/drm/card*/device/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
  printf '%s  gpu=%-8s temp=%3s°C  mem_disp=%5s MiB  swap=%4s MiB\n' "$(date +%T)" "$clk" "$((t/1000))" \
    "$(free -m | awk '/Mem:/{print $7}')" "$(free -m | awk '/Swap:/{print $3}')"
  sleep 1
done
EOF
chmod +x ~/bin/bc250-mon && ~/bin/bc250-mon
```

Si `pp_dpm_sclk` no refleja lo que pone el governor SMU, fíate del log del governor o instala `amdgpu_top`.

**Comprobación:** Ollama parado, más de 14 GiB disponibles, 40 CU activos, Vulkan ve la BC-250 con RADV, y el monitor muestra la GPU sin superar 1500 MHz cuando la pongas en carga.

## Fase 2: copiar y compilar el fork

Aquí se clona llama.cpp en el commit exacto sobre el que se hicieron los parches, se aplican los 5 commits del fork y se compila con Vulkan.

**2.1 Copia el paquete** (en tu PC):

```bash
scp llama.cpp-gfx1013-fork.tar.gz <usuario>@192.168.0.104:~
```

Y en la BC-250:

```bash
mkdir -p ~/llama.cpp-gfx1013 && tar xzf ~/llama.cpp-gfx1013-fork.tar.gz -C ~/llama.cpp-gfx1013
ls ~/llama.cpp-gfx1013          # APLICAR.md  bc250  llama.cpp-gfx1013.bundle  patches
```

**2.2 Clona llama.cpp y aplica los parches:**

```bash
sudo mkdir -p $LL && sudo chown "$USER": $LL
git clone https://github.com/ggml-org/llama.cpp $LL && cd $LL
git checkout -b gfx1013 b79696f1f
git -c user.name="Juan" -c user.email="juan@llm-box.local" am ~/llama.cpp-gfx1013/patches/*.patch
git log --oneline -6
```

`git am` necesita un nombre y correo para registrar los commits; los `-c` evitan tener que configurarlo. Deben salir, de más nuevo a más antiguo:

1. `bc250: build script, A/B benchmark sweep, llama-server router presets`
2. `vulkan: do not stage FA K/V through shmem when it does not fit`
3. `vulkan: RDNA1 rm_kq=4 for K-quant mat-vec, plus runtime tuning knobs`
4. `vulkan: Q4_K smin — algebraic restructure matching Q5_K`
5. `vulkan: enable FA shmem staging on AMD RDNA (scalar path)`
6. `b79696f1f ggml-cuda: hip: tune GCN MMQ configs (#30021)`

**2.3 Compila:**

Instala antes las dependencias a mano. El script solo las instala si falta `glslc` o el cargador de Vulkan, así que en una placa que ya compiló stable-diffusion.cpp se salta `ninja` y la configuración falla con «unable to find a build program corresponding to Ninja»:

```bash
sudo dnf install -y git cmake ninja-build gcc gcc-c++ glslc vulkan-headers vulkan-loader-devel spirv-headers-devel libcurl-devel
```

Si ya te falló una vez, borra la carpeta `build` antes de repetir (`rm -rf $LL/build`): CMake guarda la configuración fallida y no la rehace solo.

```bash
cd $LL
./bc250/build-fedora.sh
cmake --build build -j6 --target test-backend-ops llama-completion llama-perplexity
```

El script instala las dependencias con `dnf` y compila `llama-server`, `llama-bench` y `llama-cli`; la segunda línea añade las herramientas de prueba de la fase 4. Tarda un buen rato porque compila cientos de shaders. Un aviso de CMake sobre `LLAMA_CURL` obsoleto es inofensivo.

**2.4 Comprueba que el binario ve la placa y que el fork está activo:**

```bash
./build/bin/llama-bench --list-devices
# Vulkan0: AMD BC-250 (RADV GFX1013) (… MiB, … MiB free)

./build/bin/llama-completion -m $M -ngl 99 -c 4096 -fa on -lm none -no-cnv -n 16 -p "Hola" -v 2>&1 \
  | grep -i -E 'rows per workgroup|offloaded|eval time|error|failed'
```

**Pon siempre `-c` (tamaño de contexto) en las pruebas a mano.** Si no lo pones, llama.cpp reserva el contexto completo del modelo (262K tokens en Qwen3.6, unos 5 GB de caché KV). Además, la BC-250 dice tener 16,5 GB libres cuando en realidad hay unos 14, así que el ajuste automático no lo recorta. Resultado: el kernel mata el proceso sin ningún mensaje (`Killed`, código de salida 137, y en `dmesg` aparece el informe de OOM). En `models.ini` ya va fijado (`ctx-size 32768`), así que esto solo afecta a `llama-completion` y `llama-cli`. Con `-c 32768` y la caché en q8\_0 (`-ctk q8_0 -ctv q8_0`) también cabe.

Sin `-v`, esta versión oculta los mensajes de carga, así que no verás las líneas `rows per workgroup` ni `offloaded`. Lo correcto en la BC-250 es `mat-vec rows per workgroup: stdq=1 kq=4 iq=4` y `offloaded 41/41 layers to GPU`. Primera medida real (14/11/2026, Qwen3.6-35B-A3B UD-IQ2\_M, `-c 4096`): **78,2 tok/s de generación**, frente a 48,6 con Ollama.

En la salida tiene que aparecer `ggml_vulkan: mat-vec rows per workgroup: stdq=1 kq=4 iq=4`. Esa línea solo se imprime si llama.cpp identifica la GPU como RDNA1; si no sale, los ajustes del fork no se están aplicando (si aún no tienes el modelo en `$M`, haz esta última prueba al terminar la fase 3).

**Comprobación:** los 5 commits están en `git log`, la compilación termina sin errores, `--list-devices` muestra la BC-250 y aparece la línea de filas por workgroup.

## Fase 3: preparar los modelos

Los modelos van a `/models` con los nombres que espera `bc250/models.ini`. El principal ya lo tienes; los otros tres son opcionales y puedes añadirlos más tarde.

**3.1 Carpeta y modelo principal.** Copia el GGUF que localizaste en la fase 0 (si es un blob de Ollama, necesita `sudo`):

```bash
# Si ls -lL "$M" ya muestra el fichero, este paso está hecho: sáltalo.
# SRC = la ruta del GGUF que sacaste en la fase 0.2 (cámbiala por la tuya)
SRC=/home/admin/models/qwen35-moe/Qwen3.6-35B-A3B-UD-IQ2_M.gguf
sudo mkdir -p /models/src
# enlace duro (no ocupa espacio); si falla por estar en otra partición, copia
sudo ln "$SRC" "$M" || sudo cp "$SRC" "$M"
sudo chmod a+r "$M"
ls -lL "$M"
```

Si no lo encuentras, descárgalo:

```bash
hf download unsloth/Qwen3.6-35B-A3B-GGUF --include "*UD-IQ2_M*" --local-dir /models/src/qwen36
ln -sf "$(ls /models/src/qwen36/*UD-IQ2_M*.gguf | head -1)" $M
```

**3.2 Modelos opcionales** (los nombres de repositorio pueden cambiar; si alguno falla, búscalo en Hugging Face):

Antes de descargar, instala el cliente `hf` de Hugging Face (Fedora no lo trae) y comprueba que hay sitio: los tres modelos suman unos 22 GB.

```bash
dnf install -y python3-pip
pip install -U huggingface_hub
hf version
df -h /models
```

```bash
# gpt-oss-20b, MXFP4 nativo (~12 GB): razonamiento y herramientas
# el repo trae también borradores EAGLE3 (eagle3-*.gguf): enlaza el MXFP4 por su nombre
hf download ggml-org/gpt-oss-20b-GGUF --include "gpt-oss-20b-MXFP4.gguf" --local-dir /models/src/gptoss
ln -sf /models/src/gptoss/gpt-oss-20b-MXFP4.gguf /models/gpt-oss-20b-mxfp4.gguf

# Qwen3.5-9B Q4_K_M + proyector de visión (~6 GB)
hf download unsloth/Qwen3.5-9B-GGUF --include "*Q4_K_M*" --include "*mmproj*F16*" --local-dir /models/src/qwen35-9b
ln -sf "$(ls /models/src/qwen35-9b/*Q4_K_M*.gguf | head -1)" /models/Qwen3.5-9B-Q4_K_M.gguf
ln -sf "$(ls /models/src/qwen35-9b/*mmproj*F16*.gguf | head -1)" /models/mmproj-Qwen3.5-9B-F16.gguf

# Granite 4.0-H-Tiny Q4_K_M (~4 GB): clasificar y extraer
hf download unsloth/granite-4.0-h-tiny-GGUF --include "*Q4_K_M*" --local-dir /models/src/granite
ln -sf "$(ls /models/src/granite/*Q4_K_M*.gguf | head -1)" /models/granite-4.0-h-tiny-Q4_K_M.gguf
```

Si prefieres otros ficheros o rutas, cambia las líneas `model =` de `bc250/models.ini` en lugar de los enlaces.

**3.3 Permisos y comprobación.** El servicio correrá con un usuario propio, así que todo debe ser legible por cualquiera:

```bash
chmod -R a+rX /models
ls -lhL /models/*.gguf
for f in /models/*.gguf; do printf '%-50s %s\n' "$(basename $f)" "$(head -c4 "$f")"; done
```

**Comprobación:** cada `.gguf` de `/models` existe, tiene el tamaño esperado (el principal, unos 10,7 GiB) y empieza por los bytes `GGUF`. Si en la fase 2 no hiciste la prueba de `rows per workgroup`, hazla ahora.

## Fase 4: pruebas de corrección en la GPU real

Antes de medir velocidad hay que confirmar que el fork calcula bien en la BC-250. Son tres pruebas, de la más fina a la más global; las tres se hacen con el monitor abierto y el reloj a 1500 MHz.

**4.1 Kernels frente a la CPU** (`test-backend-ops` compara cada operación de la GPU con la de la CPU):

```bash
cd $LL
./build/bin/test-backend-ops test -b Vulkan0 -o MUL_MAT,MUL_MAT_ID 2>&1 | tee ~/t-mulmat.log | tail -3
GGML_VK_RM_IQ=8 ./build/bin/test-backend-ops test -b Vulkan0 -o MUL_MAT,MUL_MAT_ID 2>&1 | tee ~/t-mulmat-iq8.log | tail -3
./build/bin/test-backend-ops test -b Vulkan0 -o FLASH_ATTN_EXT 2>&1 | tee ~/t-fa.log | tail -3
grep -c FAIL ~/t-mulmat.log ~/t-mulmat-iq8.log ~/t-fa.log
```

La primera ejecución prueba los valores por defecto del fork (filas kq=4, iq=4); la segunda, iq=8, que se probará en el benchmark; la tercera, flash attention con el staging del PR #28507, que en la BC-250 queda activo por defecto. Cada ejecución debe terminar en `OK`, con 0 líneas `FAIL` y sin `GGML_ASSERT`. Si quieres la batería completa, quita `-o …` y déjala correr.

**4.2 Mismo texto que el comportamiento de master.** Con temperatura 0 la generación es determinista, así que el fork con sus ajustes y el fork con los ajustes de master (`GGML_VK_RM_KQ=2 GGML_VK_FA_SHMEM_STAGING=0`) deben escribir lo mismo o casi:

```bash
P="Explica en cinco frases qué es una red SD-WAN y para qué sirve."
./build/bin/llama-completion -m $M -ngl 99 -c 4096 -fa on -lm none -no-cnv --temp 0 -n 200 -p "$P" 2>/dev/null > ~/fork.txt
GGML_VK_RM_KQ=2 GGML_VK_FA_SHMEM_STAGING=0 \
  ./build/bin/llama-completion -m $M -ngl 99 -c 4096 -fa on -lm none -no-cnv --temp 0 -n 200 -p "$P" 2>/dev/null > ~/master.txt
diff ~/fork.txt ~/master.txt && echo IGUALES
```

El cambio de `smin` reordena sumas en coma flotante, así que puede aparecer una diferencia hacia el final. Lo aceptable: los dos textos son coherentes y coinciden al menos en las primeras frases. Lo inaceptable: texto sin sentido o repeticiones en cualquiera de los dos.

**4.3 Perplejidad** (la medida objetiva de calidad; tarda unos minutos):

```bash
cd $LL && ./scripts/get-wikitext-2.sh
PPL="./build/bin/llama-perplexity -m $M -ngl 99 -fa on -lm none -f wikitext-2-raw/wiki.test.raw -c 2048 --chunks 20"
$PPL 2>&1 | grep 'Final estimate'
GGML_VK_RM_KQ=2 GGML_VK_FA_SHMEM_STAGING=0 $PPL 2>&1 | grep 'Final estimate'
```

Cada línea da `PPL = valor +/- margen`. Los dos valores deben coincidir dentro del margen. Como referencia, akandr midió 5,18 ± 0,13 con este mismo modelo, con otros parámetros, así que tu cifra no tiene por qué ser igual a esa.

**Comprobación:** 0 fallos en 4.1, textos coherentes en 4.2 y perplejidades iguales dentro del margen en 4.3. Si algo falla, no sigas: ve a «Problemas frecuentes» y envíame los logs.

## Fase 5: benchmark y elección de ajustes

Esta fase mide el fork en tu placa y decide qué ajustes quedan fijos. El script `bench-sweep.sh` compara cada ajuste con el comportamiento de master sin recompilar, y anota reloj y temperatura en cada punto para detectar mediciones falseadas por el calor.

**5.1 Barrido de generación** (reloj a 1500 MHz, unos 10 minutos):

```bash
cd $LL && ./bc250/bench-sweep.sh $M decode
```

Cada línea del resumen tiene este aspecto: `etiqueta  tg128  d=0  86.90 ± 0.30 tok/s  reloj 1500Mhz→1500Mhz  temp 61C→74C`.

| Etiqueta | Qué prueba |
| --- | --- |
| `tg-upstream-kq2-iq4` | Comportamiento de master (referencia) |
| `tg-fork-kq4-iq4` | Valores por defecto del fork |
| `tg-kq4-iq8` | Lo que hacía el fork de TechMakesArt |
| `tg-kq4-iq2` | Menos filas en los i-quants |
| `tg-fork-depth` | Valores del fork con 4K y 16K de contexto ocupado |

Cómo decidir:

1. Descarta cualquier línea cuyo reloj acabe por debajo de 1500 MHz y repítela con más pausa: `COOL=120 ./bc250/bench-sweep.sh $M decode`.
2. Quédate con la combinación más rápida en `d=0`. Si su ventaja sobre la de por defecto es menor que el margen `±`, deja la de por defecto.
3. Apunta los valores ganadores de `GGML_VK_RM_KQ` y `GGML_VK_RM_IQ`. **Medido en tu placa el 14/11/2026: ganan los valores por defecto del fork (`kq=4`, `iq=4`, 86,1 tok/s), así que no hay que fijar ninguna variable.** En prefill gana `ubatch-size = 2048`: 946 tok/s frente a 650 con 512.

**5.2 Barrido de prefill** (unos 20–30 minutos):

```bash
./bc250/bench-sweep.sh $M prefill
```

Compara `pp-staging0-dN` con `pp-staging1-dN` en cada profundidad. Lo esperado, según las medidas publicadas en esta placa, es poca diferencia sin contexto, alrededor de un 35 % más rápido a 4K y más del doble a 16K. Del bloque `pp-ubatch`, apunta el `-ub` más rápido de 256, 512 y 1024.

**5.3 Prueba a 1700 MHz.** Sube el punto más alto del governor a 1700 MHz con unos 925 mV (setnev midió un 4,6 % más de generación en el 9B a 1700 MHz y 912,5 mV), reinicia el governor y repite solo la generación con los ajustes ganadores:

```bash
sudo systemctl restart cyan-skillfish-governor-smu
# kq=4 / iq=4 son los valores por defecto del fork: no hace falta ninguna variable
./bc250/bench-sweep.sh $M decode
```

Mantén 1700 MHz si gana velocidad, el reloj no cae y la temperatura se queda por debajo de 85 °C (a partir de ahí empieza el throttling). Si ves artefactos o cuelgues, sube 10–25 mV o vuelve a 1500 MHz. Prueba 1800 o 2000 MHz con la misma regla solo si tienes buena ventilación.

**5.4 (Opcional) Otros modelos:**

```bash
./bc250/bench-sweep.sh /models/gpt-oss-20b-mxfp4.gguf decode
./bc250/bench-sweep.sh /models/Qwen3.5-9B-Q4_K_M.gguf decode
```

El 9B es denso y Q4\_K\_M, así que es donde más debe notarse el cambio de `smin` y de `rm_kq`.

**Comprobación:** con los ajustes elegidos, `tg128` a `d=0` en el MoE da **80 tok/s o más** con el reloj estable. Guarda la carpeta `bench-<fecha>` completa: es lo que necesito si quieres que lo revise.

## Fase 6: llama-server con un modelo

Antes de montar el servicio, el servidor se prueba a mano con el MoE: velocidad real por la API, thinking apagado, reutilización del historial entre turnos, tool-calling y contexto largo.

**6.1 Arranca el servidor** en una terminal (sustituye los valores ganadores de la fase 5):

```bash
cd $LL
./build/bin/llama-server -m $M -ngl 99 -fa on -t 6 -lm none -np 1 -c 32768 -b 2048 -ub 2048 \
  -ctk q8_0 -ctv q8_0 --jinja --reasoning off -bs \
  --cache-ram 1024 --ctx-checkpoints 8 --checkpoint-min-step 1024 \
  --host 0.0.0.0 --port 8080 --metrics
```

`-bs` (`--backend-sampling`) hace el muestreo en la GPU. Medido en tu placa (14/11/2026, 3 respuestas de 400 tokens): **79,6 tok/s sin `-bs` y 83,0 con `-bs`**, con texto coherente. En `models.ini` va como `backend-sampling = true`.

En otra terminal define `API=http://localhost:8080` y comprueba que responde:

```bash
export API=http://localhost:8080
curl -s $API/health          # {"status":"ok"}
```

**6.2 Velocidad por la API** (tres veces):

```bash
for i in 1 2 3; do
  curl -s $API/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "messages":[{"role":"user","content":"Explica qué es SD-WAN en 300 palabras."}],"max_tokens":400}' \
  | jq '.timings | {predicted_per_second, predicted_n, prompt_per_second}'
done
```

El dato es `predicted_per_second`. Objetivo: 80 o más. Es normal que quede un poco por debajo de `llama-bench` (en el 9B, setnev midió \~52 en benchmark frente a \~49 en la API).

**6.3 Thinking apagado:**

```bash
curl -s $API/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"¿Cuánto es 17*23?"}],"max_tokens":100}' \
  | jq '.choices[0].message | {content, razonamiento: (.reasoning_content // "ninguno")}'
```

Debe salir la respuesta directa y `razonamiento: "ninguno"`. Esto resuelve lo que no conseguimos con el Modelfile de Ollama.

**6.4 Reutilización del historial entre turnos.** Qwen3.6 es híbrido: sin checkpoints, cada turno reprocesa el prompt entero. Esta prueba manda un prompt de sistema de unos 3.000 tokens y luego un segundo turno que lo repite:

```bash
SYS=$(for i in $(seq 1 150); do echo "Regla $i: responde en español técnico, con frases cortas y sin relleno."; done)
req() { curl -s $API/v1/chat/completions -H 'Content-Type: application/json' -d "$1"; }
R1=$(req "$(jq -n --arg s "$SYS" '{messages:[{role:"system",content:$s},{role:"user",content:"¿Qué es BGP?"}],max_tokens:150}')")
echo "$R1" | jq '.timings | {cache_n, prompt_n, prompt_ms}'
A1=$(echo "$R1" | jq -r '.choices[0].message.content')
req "$(jq -n --arg s "$SYS" --arg a "$A1" '{messages:[{role:"system",content:$s},{role:"user",content:"¿Qué es BGP?"},{role:"assistant",content:$a},{role:"user",content:"¿Y OSPF?"}],max_tokens:150}')" \
  | jq '.timings | {cache_n, prompt_n, prompt_ms}'
```

En el primer turno `cache_n` es 0 y `prompt_n` ronda 3.000. En el segundo, `cache_n` debe ser grande y `prompt_n` pequeño (unos cientos), con un `prompt_ms` muy inferior. Si el segundo vuelve a procesar casi todo, los checkpoints no están funcionando: ve a «Problemas frecuentes».

**6.5 Tool-calling** (el pendiente que arrastrabas desde verano):

```bash
curl -s $API/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages":[{"role":"user","content":"¿Qué tiempo hace en Valencia?"}],
  "tools":[{"type":"function","function":{"name":"get_weather","description":"Tiempo actual de una ciudad",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
  "max_tokens":200}' | jq '.choices[0] | {finish_reason, tool_calls: .message.tool_calls}'
```

Debe devolver `finish_reason: "tool_calls"` y una llamada a `get_weather` con `city: "Valencia"`.

**6.6 Contexto largo (unos 16.000–20.000 tokens de entrada):**

```bash
LONG=$(for i in $(seq 1 800); do echo "Línea $i del registro: el enlace principal de la sede $((i % 13)) estuvo operativo."; done)
req "$(jq -n --arg t "$LONG" '{messages:[{role:"user",content:($t + "\n\nResume el registro en tres frases.")}],max_tokens:200}')" \
  | jq '.timings | {prompt_n, prompt_per_second, predicted_per_second}'
```

Vigila el monitor: no debe usarse swap. Como referencia, con 16K de contexto la generación del MoE baja a unos 78 tok/s.

**Comprobación:** `health` OK, 80 tok/s o más en 6.2, sin razonamiento en 6.3, segundo turno con `prompt_n` pequeño en 6.4, llamada a herramienta correcta en 6.5 y sin swap en 6.6. Para el servidor con Ctrl+C al terminar.

## Fase 7: modo router y servicio systemd

El servicio definitivo usa el modo router de llama-server: un único proceso en el puerto 8080 que carga el modelo que pida cada petición, con un modelo en memoria a la vez y descarga tras 10 minutos sin uso. Sustituye a Ollama también en la gestión de modelos.

**7.1 Usuario, configuración y clave:**

```bash
sudo useradd -r -d $LL -s /sbin/nologin llama
sudo install -d -m755 /etc/llama
sudo install -m644 $LL/bc250/models.ini /etc/llama/models.ini
sudoedit /etc/llama/models.ini
```

En `models.ini`, comprueba que la sección `[*]` lleva `batch-size = 2048` y `ubatch-size = 2048` (la versión actual del fork ya los trae; si no, añádelos). Revisa también las rutas `model =` y borra las secciones de los modelos que no hayas descargado.

```bash
KEY=$(openssl rand -hex 24)
echo "LLAMA_API_KEY=$KEY" | sudo tee /etc/llama/env >/dev/null && sudo chmod 600 /etc/llama/env
echo "$KEY"      # guárdala en Vaultwarden: la necesitarán LiteLLM, Open WebUI y n8n
```

**7.2 Instala el servicio con tus ajustes:**

```bash
sudo install -m644 $LL/bc250/llama-server.service /etc/systemd/system/
sudo systemctl edit llama-server
```

Con tus medidas (`kq=4`, `iq=4`) no hay que añadir nada aquí, porque son los valores del fork: cierra el editor sin cambios. Este paso solo hace falta si en otra placa ganara otro valor. En ese caso, los procesos de cada modelo heredan estas variables:

```ini
# Solo si el barrido diera otros ganadores (en tu BC-250 no hace falta):
[Service]
Environment=GGML_VK_RM_KQ=4
Environment=GGML_VK_RM_IQ=4
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now llama-server
# Fedora solo tiene abierto el puerto de Ollama (11434): abre el 8080 y cierra el viejo
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --remove-port=11434/tcp
sudo firewall-cmd --reload && sudo firewall-cmd --list-ports
journalctl -u llama-server -f        # déjalo abierto en otra terminal
```

**7.3 Pruebas del router:**

```bash
export API=http://localhost:8080 AUTH="Authorization: Bearer $KEY"
curl -s $API/health                                            # {"status":"ok"}, sin clave
curl -s -o /dev/null -w '%{http_code}\n' $API/v1/models         # 401: sin clave se rechaza
curl -s -H "$AUTH" $API/v1/models | jq -r '.data[].id'          # tus presets

ask() {  # ask <modelo>: mide una petición completa
  /usr/bin/time -f 'total %es' curl -s -H "$AUTH" -H 'Content-Type: application/json' $API/v1/chat/completions \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Explica qué es SD-WAN en 200 palabras.\"}],\"max_tokens\":300}" \
    | jq '.timings | {predicted_per_second, prompt_n}'
}
ask qwen36-moe      # primera vez: incluye la carga del modelo
ask qwen36-moe      # segunda: sin carga, 80 tok/s o más
ask gpt-oss-20b     # el router descarga el MoE y carga gpt-oss (mira el monitor)
ask qwen36-moe      # vuelta al MoE
```

Si `/usr/bin/time` no existe, instálalo con `sudo dnf install -y time`. En el journal debe aparecer, para cada modelo cargado, la línea `mat-vec rows per workgroup` con tus valores.

**7.4 Descarga por inactividad.** Deja el servidor 11 minutos sin peticiones y comprueba:

```bash
curl -s -H "$AUTH" "$API/props?model=qwen36-moe" | jq .is_sleeping   # true
free -h                                                              # la memoria vuelve a estar disponible
```

**7.5 Arranque tras reinicio:**

```bash
sudo systemctl reboot
# tras el arranque:
systemctl is-active cyan-skillfish-governor-smu llama-server        # active / active
curl -s localhost:8080/health
```

**Comprobación:** el servicio arranca solo tras un reinicio, rechaza peticiones sin clave, lista los presets, cambia de modelo sin agotar la memoria, mantiene 80 tok/s o más en el MoE una vez cargado y se duerme tras 10 minutos de inactividad. Apunta también cuánto tarda la carga en frío del MoE: la necesitas para el timeout de LiteLLM en la fase 8.

## Fase 8: integración con LiteLLM, Open WebUI y n8n

Los clientes dejan de hablar con Ollama (puerto 11434) y pasan a llama-server (8080), mejor a través de LiteLLM para conservar el fallback a DeepSeek de la Vía D. llama-server habla la API de OpenAI, así que el cambio es de URL, clave y nombre de modelo.

Si has abierto una sesión nueva, recupera la clave: `KEY=$(sudo sed -n 's/^LLAMA_API_KEY=//p' /etc/llama/env)`.

**8.1 LiteLLM.** En `litellm_config.yaml`, cambia las entradas locales de `ollama_chat/…` a `openai/<preset>`:

```yaml
model_list:
  - model_name: smart
    litellm_params:
      model: openai/qwen36-moe
      api_base: http://192.168.0.104:8080/v1
      api_key: os.environ/BC250_API_KEY
      timeout: 60
      stream_timeout: 60
  - model_name: local-qwen
    litellm_params:
      model: openai/qwen35-9b
      api_base: http://192.168.0.104:8080/v1
      api_key: os.environ/BC250_API_KEY
      timeout: 60
  - model_name: local-qwen-moe
    litellm_params:
      model: openai/qwen36-moe-think
      api_base: http://192.168.0.104:8080/v1
      api_key: os.environ/BC250_API_KEY
      timeout: 120
  # … deepseek-chat, deepseek-reasoner y la sección de fallbacks, sin cambios
```

Añade `BC250_API_KEY=<la clave>` al `.env` del compose y reinicia el contenedor. El timeout antes era de 20 s; súbelo por encima de la carga en frío que mediste en la fase 7 (más unos 30 s de margen), o el primer mensaje tras una descarga por inactividad saltará a DeepSeek sin necesidad.

**8.2 Prueba de LiteLLM y del fallback** (desde cualquier máquina de la red):

```bash
LITE=http://<host-litellm>:4000
curl -s $LITE/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"smart","messages":[{"role":"user","content":"Di hola en una frase."}]}' | jq '{model, usage}'

# fallback: para llama-server en la BC-250 y repite la misma petición
sudo systemctl stop llama-server        # en la BC-250
# …repite el curl: ahora debe responder DeepSeek (campo model)
sudo systemctl start llama-server       # en la BC-250
```

**8.3 Open WebUI.** Lo más simple es que apunte a LiteLLM, y entonces no hay que tocar nada. Si apunta directamente a la placa: Admin → Settings → Connections, añade una conexión de tipo OpenAI con URL `http://192.168.0.104:8080/v1` y la clave, y desactiva la conexión de Ollama a `:11434`. Manda un mensaje y comprueba en `journalctl -u llama-server -f` que llega la petición (en junio el problema era que Open WebUI solo consultaba la lista de modelos y nunca enviaba el chat).

**8.4 n8n.** En los nodos de chat, usa una credencial de tipo OpenAI con la URL base de LiteLLM (`http://<host-litellm>:4000/v1`) y su clave maestra, y el modelo `smart`. Lanza un flujo existente que antes usara Ollama.

**Comprobación:** una petición a `smart` por LiteLLM llega a la BC-250; con llama-server parado responde DeepSeek; Open WebUI y un flujo de n8n funcionan contra el nuevo servidor.

## Fase 9: prueba de resistencia de 30 minutos

Las fases anteriores son pruebas cortas; esta comprueba que la velocidad, la temperatura y la memoria aguantan con carga continua, que es donde aparecen el throttling y los cuelgues. Usa el servicio de la fase 7.

**9.1 Crea el script:**

```bash
cat > ~/bin/bc250-soak <<'EOF'
#!/usr/bin/env bash
# Carga continua contra llama-server durante N minutos (por defecto 30).
# Uso: KEY=<clave> bc250-soak [minutos] [modelo]
set -u
MIN=${1:-30}; MODEL=${2:-qwen36-moe}; API=${API:-http://localhost:8080}
OUT=~/soak-$(date +%Y%m%d-%H%M); mkdir -p "$OUT"
# Monitor en segundo plano: reloj, temperatura, memoria y swap cada 2 s
( while :; do
    clk=$(grep -h '\*' /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null | head -1 | awk '{print $2}' | tr -dc 0-9)
    t=$(cat /sys/class/drm/card*/device/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
    echo "$(date +%s),${clk},$(( ${t:-0} / 1000 )),$(free -m | awk '/Mem:/{print $7}'),$(free -m | awk '/Swap:/{print $3}')"
    sleep 2
  done ) > "$OUT/monitor.csv" &
MON=$!; trap 'kill $MON 2>/dev/null' EXIT
END=$((SECONDS + MIN * 60)); n=0; err=0
while [ $SECONDS -lt $END ]; do
  r=$(curl -s -m 300 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' $API/v1/chat/completions \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Escribe 400 palabras sobre redes SD-WAN, variante $n.\"}],\"max_tokens\":500}")
  tps=$(echo "$r" | jq -r '.timings.predicted_per_second // empty' 2>/dev/null)
  if [ -z "$tps" ]; then err=$((err+1)); echo "error en petición $n"; sleep 2; else echo "$(date +%s),$tps" >> "$OUT/tps.csv"; fi
  n=$((n+1)); printf '\rpeticiones=%d errores=%d última=%s tok/s ' $n $err "$tps"
done
echo
[ -s "$OUT/tps.csv" ] && awk -F, 'NR<=5{a+=$2;na++} {v[NR]=$2} END{s=(NR>5?NR-4:1); for(i=s;i<=NR;i++){b+=v[i];nb++}; printf "tok/s primeras 5: %.1f  últimas 5: %.1f\n", a/na, b/nb}' "$OUT/tps.csv"
awk -F, '{if($3>tm)tm=$3; if($2!="" && (cmin=="" || $2+0<cmin+0))cmin=$2; if($5>sw)sw=$5; if(mm=="" || $4+0<mm+0)mm=$4} END{printf "temp máx: %d °C  reloj mín: %s MHz  memoria disp. mín: %d MiB  swap máx: %d MiB\n", tm, cmin, mm, sw}' "$OUT/monitor.csv"
echo "errores: $err   datos en $OUT"
EOF
chmod +x ~/bin/bc250-soak
```

**9.2 Lánzalo** y déjalo correr sin tocar la placa:

```bash
KEY=$(sudo sed -n 's/^LLAMA_API_KEY=//p' /etc/llama/env) ~/bin/bc250-soak 30 qwen36-moe
journalctl -u llama-server --since "35 min ago" | grep -i -E 'error|assert|fail|lost|reset' | tail
sudo dmesg | grep -i -E 'amdgpu|ring|timeout|reset' | tail
```

El reloj mínimo cuenta el reposo entre peticiones; lo importante es que no aparezcan muestras de 1000 MHz en mitad de la carga (míralo en `monitor.csv` si la media cae).

**Comprobación:**

| Medida | Criterio |
| --- | --- |
| tok/s de las últimas 5 peticiones frente a las primeras 5 | Menos de un 5 % de caída |
| Temperatura máxima | Por debajo de 85 °C |
| Swap máximo | 0 o casi 0 MiB |
| Errores de petición | 0 |
| Journal y `dmesg` | Sin `assert`, sin reinicios del ring ni timeouts de amdgpu |

Si la velocidad cae y la temperatura pasa de 85 °C, baja el reloj o el voltaje (fase 5.3) o mejora la ventilación, y repite.

## Vuelta atrás

Hay cuatro niveles, del más ligero al completo; ninguno necesita reinstalar nada, porque Ollama y sus modelos siguen en la placa.

| Nivel | Cuándo | Qué hacer |
| --- | --- | --- |
| 1. Quitar los ajustes del fork | Salida rara o fallos que no tenías con master | `sudo systemctl edit llama-server` y deja `Environment=GGML_VK_RM_KQ=2` y `Environment=GGML_VK_FA_SHMEM_STAGING=0`; reinicia el servicio. Equivale al comportamiento de master (el cambio de `smin` es algebraicamente equivalente y la corrección del staging solo actúa con el staging activo) |
| 2. llama.cpp master sin parches | Quieres descartar el fork por completo | `cd $LL && git checkout -b master-puro b79696f1f && cmake --build build -j6 --target llama-server llama-bench` y reinicia el servicio. Perderás el prefill rápido con contexto, no la generación |
| 3. Volver a Ollama | Algo no funciona y necesitas el servicio ya | Comandos de abajo |
| 4. Snapshot LVM | Solo si hiciste el de la fase 0.4 y algo del sistema se rompió | `sudo lvconvert --merge /dev/<vg>/root_pre_llamacpp` y reinicia |

Volver a Ollama:

```bash
sudo systemctl disable --now llama-server
sudo systemctl reboot                     # libera la memoria de la GPU
sudo systemctl enable --now ollama        # tras el reinicio
curl -s localhost:11434/api/tags | jq -r '.models[].name'
```

En LiteLLM, vuelve a poner las entradas `ollama_chat/…` con `api_base: http://192.168.0.104:11434` (las tienes en el backup de la fase 0). Para el reloj, restaura `~/backup-pre-llamacpp/cyan-skillfish-governor-smu/config.toml` y reinicia el governor.

Para borrar la instalación del todo, además:

```bash
sudo rm /etc/systemd/system/llama-server.service && sudo rm -rf /etc/systemd/system/llama-server.service.d /etc/llama
sudo systemctl daemon-reload && sudo userdel llama
sudo rm -rf $LL            # y /models si no lo quieres conservar
```

## Problemas frecuentes

Ordenados por fase. Si un síntoma no está aquí, guarda el log y la salida del monitor y pásamelos.

| Fase | Síntoma | Causa probable | Qué hacer |
| --- | --- | --- | --- |
| 2 | `git am` falla con «Please tell me who you are» | Falta identidad de git | Usa el comando con `-c user.name=… -c user.email=…` |
| 2 | `git am` falla con conflictos | No estás en `b79696f1f` | `git am --abort`, `git checkout -B gfx1013 b79696f1f` y repite |
| 2 | Falta `glslc` o `vulkan/vulkan.h` al compilar | Dependencias | `sudo dnf install -y glslc vulkan-headers vulkan-loader-devel spirv-headers-devel` |
| 2 | `--list-devices` no muestra la BC-250 o muestra `llvmpipe` | El usuario no puede abrir la GPU o Mesa no la ve | `ls -l /dev/dri/`, añádete a los grupos `video` y `render`, revisa `vulkaninfo --summary` |
| 2 | No aparece `mat-vec rows per workgroup` | llama.cpp no identifica la GPU como RDNA1 y los ajustes del fork no actúan | Envíame la salida de `vulkaninfo` (secciones de extensiones y `shaderCoreProperties`) |
| 3 | El modelo no carga, error de formato | Enlace roto o descarga incompleta | `ls -lL`, comprueba que empieza por `GGUF` y vuelve a descargar |
| 4 | `FAIL` en `test-backend-ops` | Error de cálculo en la GPU real | Repite con `GGML_VK_RM_KQ=2 GGML_VK_RM_IQ=4 GGML_VK_FA_SHMEM_STAGING=0` para aislar qué ajuste falla, y envíame el log |
| 4–6 | Aborta con `GGML_ASSERT` en flash attention | Caso de staging no cubierto | Fija `GGML_VK_FA_SHMEM_STAGING=0` y envíame el log |
| 4–6 | Texto sin sentido o repetitivo | Ajuste del fork incorrecto en esta placa | Igual que el `FAIL`: desactiva ajustes uno a uno |
| 5–6 | Generación por debajo de 80 tok/s | Throttling (reloj a 1000 MHz) | Mira el monitor; más pausa entre pruebas, menos reloj o mejor ventilación |
| 5–6 | Igual, con reloj estable | 24 CU activos | Fase 1.2: `bc250_cc_write_mode` debe valer 3; el prefill pp512 ronda 457 con 40 CU y cae claramente con 24 |
| 5–6 | Igual, con swap en uso | Falta memoria: Ollama u otro proceso ocupa RAM | `free -h`, reinicia tras parar Ollama, baja `-c` o `--cache-ram` |
| 6 | La respuesta tarda pero los tok/s son buenos | El thinking está activo o el prompt es largo | Comprueba `--reasoning off` y mira `prompt_n` y `prompt_ms` |
| 6–8 | Cada turno reprocesa todo el historial | Los checkpoints no alcanzan o el cliente cambia el prompt de sistema en cada turno | Baja `--checkpoint-min-step` a 512; en Open WebUI quita variables que cambian en cada mensaje (fecha, hora) del prompt de sistema |
| 6–7 | Cuelgue o reinicio de la placa con contexto muy largo | Memoria unificada agotada | Mantén `-c 32768` y `--cache-ram 1024`; sube el contexto por pasos vigilando el swap |
| 7 | El servicio no arranca: permiso denegado al abrir el modelo | Permisos o SELinux | `chmod -R a+rX /models`; `sudo ausearch -m avc -ts recent` |
| 7 | «model limit reached, try again later» | Petición mientras otro modelo carga | Reintenta; es normal en el cambio de modelo |
| 7 | La placa no se duerme | Algún cliente hace peticiones periódicas (Open WebUI, comprobaciones de salud) | Mira el journal; `/health` y la lista de modelos no despiertan el modelo, una petición de chat sí |
| 8 | LiteLLM salta a DeepSeek en el primer mensaje | La carga en frío supera el timeout | Sube `timeout` y `stream_timeout`, o sube `--sleep-idle-seconds` |
| 8 | Open WebUI no envía los mensajes | Conexión de tipo Ollama en lugar de OpenAI | Rehaz la conexión como OpenAI, o apúntala a LiteLLM |
| 9 | La velocidad cae a lo largo de la prueba | Calor | Baja reloj o voltaje, ventila; la placa se reinicia sola por encima de unos 90 °C |

## Hoja de resultados

Rellena la columna Resultado con lo que mida tu placa y marca el estado. Si me la pegas junto con la carpeta `bench-<fecha>`, te digo qué ajustar.

| Paso | Prueba | Criterio | Resultado | Estado |
| --- | --- | --- | --- | --- |
| 0.3 | Ollama, generación (tok/s) | Referencia, \~42 |  | Pendiente |
| ☐ 1.2 | Memoria disponible, 40 CU, Vulkan ve la BC-250 | > 14 GiB, `bc250_cc_write_mode` = 3, RADV GFX1013 |  | Pendiente |
| 2.4 | Línea `mat-vec rows per workgroup` | Aparece con kq=4 iq=4 |  | Pendiente |
| 3.3 | Modelos en `/models` | Tamaños correctos, empiezan por `GGUF` |  | Pendiente |
| 4.1 | `test-backend-ops` MUL\_MAT y MUL\_MAT\_ID (por defecto) | 0 FAIL |  | Pendiente |
| 4.1 | Ídem con `GGML_VK_RM_IQ=8` | 0 FAIL |  | Pendiente |
| 4.1 | `test-backend-ops` FLASH\_ATTN\_EXT | 0 FAIL, sin assert |  | Pendiente |
| 4.2 | Texto fork frente a comportamiento master | Coherente, igual al menos al principio |  | Pendiente |
| 4.3 | Perplejidad fork / master | Iguales dentro del margen |  | Pendiente |
| 5.1 | tg128 d=0, comportamiento master (kq2-iq4) | Referencia |  | Pendiente |
| 5.1 | tg128 d=0, mejor ajuste del fork (indica KQ/IQ) | ≥ 80 tok/s, reloj estable |  | Pendiente |
| 5.1 | tg128 con 16K de contexto | Referencia, \~78 |  | Pendiente |
| 5.2 | pp2048 a 8K, staging 0 / staging 1 | Staging 1 claramente más rápido |  | Pendiente |
| 5.2 | Mejor `-ub` | Anotar |  | Pendiente |
| 5.3 | tg128 y temperatura a 1700 MHz | Más rápido que a 1500, < 85 °C |  | Pendiente |
| 6.2 | `predicted_per_second` por la API | ≥ 80 tok/s |  | Pendiente |
| 6.3 | Thinking apagado | Sin razonamiento |  | Pendiente |
| 6.4 | Segundo turno: `cache_n` / `prompt_n` | `prompt_n` de unos cientos |  | Pendiente |
| 6.5 | Tool-calling | `get_weather` con Valencia |  | Pendiente |
| 6.6 | Prompt de 16K: prefill y generación | Sin swap |  | Pendiente |
| 7.3 | Router: clave, presets, cambio de modelo, carga en frío (s) | Todo responde; anotar segundos |  | Pendiente |
| 7.4–7.5 | Descarga por inactividad y arranque tras reinicio | `is_sleeping` true; servicio activo |  | Pendiente |
| 8 | LiteLLM, fallback, Open WebUI, n8n | Los cuatro funcionan |  | Pendiente |
| 9 | Resistencia 30 min | Caída < 5 %, < 85 °C, 0 swap, 0 errores |  | Pendiente |
