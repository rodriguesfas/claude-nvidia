#!/usr/bin/env bash
# Instala/configura o claude-nvidia: proxy LiteLLM -> NVIDIA NIM + Claude Code.
# Idempotente: rode de novo que ele preserva sua chave e o resto do settings.json.
#
#   ./install-nvidia-claude-code.sh [--api-key nvapi-xxx] [--model nvidia_nim/...]
#                                   [--small-model nvidia_nim/...] [--no-test] [--e2e]
#
#   --api-key      chave da NVIDIA (senão: chave já instalada > $NVIDIA_NIM_API_KEY > prompt)
#   --model        modelo principal (padrão: nvidia_nim/nvidia/nemotron-3-super-120b-a12b)
#   --small-model  modelo pequeno/rápido (padrão: nvidia_nim/openai/gpt-oss-20b)
#   --no-test      não valida subindo o proxy no final
#   --e2e          além disso, roda um claude -p de ponta a ponta
# shellcheck disable=SC1090  # $ENVF é construído em runtime
set -euo pipefail

PREFIX="$HOME"
BIN_DIR="$PREFIX/.local/bin"
VENV_DIR="$PREFIX/.claude-nvidia/venv"
CONFIG_DIR="$PREFIX/.config/claude-nvidia"
ENVF="$CONFIG_DIR/env"
CONF="$CONFIG_DIR/config.yaml"
WRAPPER="$BIN_DIR/claude-nvidia"
SETTINGS="$PREFIX/.claude/settings.json"
LITELLM_SPEC="litellm[proxy]==1.104.0"
MARKER="# gerado por install-nvidia-claude-code.sh"

NV_MODEL_DEFAULT="nvidia_nim/nvidia/nemotron-3-super-120b-a12b"
NV_SMALL_DEFAULT="nvidia_nim/openai/gpt-oss-20b"
API_KEY_IN="${NVIDIA_NIM_API_KEY:-}"
MODEL_FROM_FLAG=0
SMALL_FROM_FLAG=0
DO_TEST=1
DO_E2E=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
aviso() { printf '\033[1;33maviso:\033[0m %s\n' "$*" >&2; }
erro() { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) API_KEY_IN="${2:?}"; shift 2 ;;
    --model) NV_MODEL_DEFAULT="${2:?}"; MODEL_FROM_FLAG=1; shift 2 ;;
    --small-model) NV_SMALL_DEFAULT="${2:?}"; SMALL_FROM_FLAG=1; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --e2e) DO_E2E=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

# ---------------------------------------------------------------- dependências
for c in python3 curl; do
  command -v "$c" >/dev/null 2>&1 || erro "precisa de '$c' no PATH"
done
command -v claude >/dev/null 2>&1 \
  || aviso "Claude Code não encontrado (npm i -g @anthropic-ai/claude-code); o wrapper instala, mas não roda."

# ------------------------------------------------------------------- venv + litellm
if [ -x "$VENV_DIR/bin/litellm" ] && "$VENV_DIR/bin/litellm" --version >/dev/null 2>&1; then
  ok "venv já existe: $VENV_DIR ($("$VENV_DIR/bin/pip" show litellm 2>/dev/null | awk '/^Version:/{print $2}'))"
else
  log "criando venv e instalando $LITELLM_SPEC (pode demorar)"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip -q
  "$VENV_DIR/bin/pip" install -q "$LITELLM_SPEC"
  ok "LiteLLM instalado em $VENV_DIR"
fi

# ------------------------------------------------------------------------ env
mkdir -p "$CONFIG_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# Preserva o que já está instalado (chave, master key e modelos) antes de reescrever.
OLD_API_KEY=""
OLD_MASTER=""
OLD_MODEL=""
OLD_SMALL=""
if [ -f "$ENVF" ]; then
  mapfile -t _old < <(set +e; source "$ENVF" >/dev/null 2>&1
    printf '%s\n%s\n%s\n%s\n' "${NVIDIA_NIM_API_KEY:-}" "${LITELLM_MASTER_KEY:-}" \
      "${NV_MODEL:-}" "${NV_SMALL_MODEL:-}")
  OLD_API_KEY="${_old[0]:-}"
  OLD_MASTER="${_old[1]:-}"
  OLD_MODEL="${_old[2]:-}"
  OLD_SMALL="${_old[3]:-}"
  if [ "$MODEL_FROM_FLAG" = 0 ] && [ -n "$OLD_MODEL" ]; then NV_MODEL_DEFAULT="$OLD_MODEL"; fi
  if [ "$SMALL_FROM_FLAG" = 0 ] && [ -n "$OLD_SMALL" ]; then NV_SMALL_DEFAULT="$OLD_SMALL"; fi
fi

API_KEY="${API_KEY_IN:-$OLD_API_KEY}"
if [ -z "$API_KEY" ]; then
  printf 'Chave da NVIDIA (nvapi-...): '
  IFS= read -rs API_KEY || true; echo
fi
[ -n "$API_KEY" ] || erro "chave NVIDIA ausente (use --api-key ou NVIDIA_NIM_API_KEY)"

MASTER_KEY="${OLD_MASTER:-}"
if [ -z "$MASTER_KEY" ]; then
  MASTER_KEY="sk-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  log "gerando LITELLM_MASTER_KEY novo"
fi

umask 077
if [ -n "$OLD_API_KEY" ]; then KEY_MSG="chave instalada preservada"
elif [ -n "$API_KEY_IN" ]; then KEY_MSG="chave via --api-key/\$NVIDIA_NIM_API_KEY"
else KEY_MSG="chave digitada"; fi
cat > "$ENVF" <<EOF
$MARKER
export NVIDIA_NIM_API_KEY="$API_KEY"

# Master key do proxy LiteLLM (exigido pela versao 1.104+)
export LITELLM_MASTER_KEY="$MASTER_KEY"

# Modelo principal do Claude Code (id da NVIDIA, com prefixo do provider).
# Lista: GET https://integrate.api.nvidia.com/v1/models
export NV_MODEL="\${NV_MODEL:-$NV_MODEL_DEFAULT}"

# Modelo pequeno/rapido (tarefas de fundo do Claude Code).
export NV_SMALL_MODEL="\${NV_SMALL_MODEL:-$NV_SMALL_DEFAULT}"
EOF
chmod 600 "$ENVF"
ok "env em $ENVF ($KEY_MSG ${API_KEY:0:7}...; $([ -n "$OLD_MASTER" ] && echo 'master key preservada' || echo 'master key nova'))"

# ------------------------------------------------------------------- config.yaml
if [ -f "$CONF" ] && ! head -1 "$CONF" | grep -q "install-nvidia-claude-code"; then
  aviso "$CONF não é do instalador; mantendo (remova para regenerar)."
else
  cat > "$CONF" <<'EOF'
# gerado por install-nvidia-claude-code.sh
model_list:
  # Principal: o upstream vem de NV_MODEL (padrao nemotron-3-super-120b-a12b).
  # temperature/top_p: recomendacao NVIDIA p/ Nemotron 3 Super em agente.
  # Se apontar NV_MODEL p/ kimi-k3, use 0.6/0.95 (temp alta faz o Kimi vazar lixo).
  - model_name: nvidia-model
    litellm_params:
      model: os.environ/NV_MODEL
      api_key: os.environ/NVIDIA_NIM_API_KEY
      temperature: 1.0
      top_p: 0.95

  # Atalhos para trocar de modelo em runtime com /model dentro do Claude Code.
  - model_name: nvidia-k3
    litellm_params:
      model: nvidia_nim/moonshotai/kimi-k3
      api_key: os.environ/NVIDIA_NIM_API_KEY
      temperature: 0.6
      top_p: 0.95

  - model_name: nvidia-glm
    litellm_params:
      model: nvidia_nim/z-ai/glm-5.3
      api_key: os.environ/NVIDIA_NIM_API_KEY
      temperature: 0.6
      top_p: 0.95

  - model_name: nvidia-nemotron
    litellm_params:
      model: nvidia_nim/nvidia/nemotron-3-super-120b-a12b
      api_key: os.environ/NVIDIA_NIM_API_KEY
      temperature: 1.0
      top_p: 0.95

  # Pequeno/rapido: vem de NV_SMALL_MODEL (tarefas de fundo do Claude Code).
  - model_name: nvidia-small
    litellm_params:
      model: os.environ/NV_SMALL_MODEL
      api_key: os.environ/NVIDIA_NIM_API_KEY

litellm_settings:
  drop_params: true
  num_retries: 2
EOF
  ok "config em $CONF"
fi

# ----------------------------------------------------------------------- wrapper
umask 022
cat > "$WRAPPER" <<'WRAP'
#!/usr/bin/env bash
# Sobe o proxy LiteLLM (NVIDIA NIM), roda o Claude Code apontando pra ele e
# encerra o proxy ao sair.
set -euo pipefail

CONFIG_DIR="@HOME@/.config/claude-nvidia"
VENV_DIR="@HOME@/.claude-nvidia/venv"
MODEL="nvidia-model"
SMALL_MODEL="nvidia-small"

# shellcheck disable=SC1091
source "$CONFIG_DIR/env"

[ -n "${LITELLM_MASTER_KEY:-}" ] || { echo "LITELLM_MASTER_KEY ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NVIDIA_NIM_API_KEY:-}" ] || { echo "NVIDIA_NIM_API_KEY ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NV_MODEL:-}" ] || { echo "NV_MODEL ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NV_SMALL_MODEL:-}" ] || { echo "NV_SMALL_MODEL ausente em $CONFIG_DIR/env" >&2; exit 1; }

echo "Modelo principal: $MODEL -> ${NV_MODEL#nvidia_nim/} | pequeno: ${NV_SMALL_MODEL#nvidia_nim/}"

proxy_pid=""

# O LiteLLM fica preso em "Waiting for background tasks to complete"; então
# TERM e, se ainda vivo em 5s, KILL — senão vira processo zumbi.
encerra_proxy() {
  [ -n "$proxy_pid" ] || return 0
  kill "$proxy_pid" 2>/dev/null || return 0
  for _ in 1 2 3 4 5; do
    kill -0 "$proxy_pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$proxy_pid" 2>/dev/null || true
}
trap encerra_proxy EXIT

# Algo está LISTEN na porta? (TCP: pega até proxy PARADO/travado, que não
# responde HTTP e faria o wrapper achar a porta "livre" e falhar no bind)
porta_tem_listener() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
  else
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" || true)"
    [ "$code" != "000" ]
  fi
}

# Responde HTTP no /health dentro de $2 segundos? (padrão 2)
http_ok() {
  local code t="${2:-2}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$t" \
    "http://127.0.0.1:$1/health/liveliness" || true)"
  [ "$code" = "200" ]
}

# pid que está escutando a porta (vazio se não der pra saber)
pid_na_porta() {
  ss -H -ltnp "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2
}

# É UM proxy claude-nvidia (o nosso venv + config), travado ou não?
eh_nosso_proxy() {
  [ -n "${1:-}" ] || return 1
  grep -qF -- "$VENV_DIR/bin/litellm" "/proc/$1/cmdline" 2>/dev/null || return 1
  grep -qF -- "$CONFIG_DIR/config.yaml" "/proc/$1/cmdline" 2>/dev/null
}

# É um proxy claude-nvidia JÁ com a config atual? Exige todos os model_name do
# config.yaml (atualizados no proxy rodando) + os upstreams atuais do env.
proxy_compativel() {
  local info n
  info="$(curl -fs --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    "http://127.0.0.1:$1/v1/model/info" 2>/dev/null)" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s' "$info" | grep -q "\"model_name\":\"$n\"" || return 1
  done < <(grep -E '^[[:space:]]*-[[:space:]]*model_name:' "$CONFIG_DIR/config.yaml" | sed -E 's/.*model_name:[[:space:]]*//')
  # upstream do principal e do pequeno precisam bater com o env ATUAL
  printf '%s' "$info" | NV_MODEL="$NV_MODEL" NV_SMALL_MODEL="$NV_SMALL_MODEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
data = d.get("data") if isinstance(d, dict) else d
up = {e.get("model_name"): (e.get("litellm_params") or {}).get("model") for e in data}
ok = up.get("nvidia-model") == os.environ["NV_MODEL"] and up.get("nvidia-small") == os.environ["NV_SMALL_MODEL"]
sys.exit(0 if ok else 1)'
}

# Porta: livre -> usar; proxy nosso com a mesma config -> reusar; proxy nosso
# TRAVADO (escuta mas não responde: Ctrl+Z, incidente) -> reinicia; ocupada por
# outro serviço -> próxima porta. Assim a sessão antiga nunca derruba a nova.
if [ -n "${CLAUDE_NVIDIA_PORT:-}" ]; then
  candidatas=("$CLAUDE_NVIDIA_PORT")
else
  candidatas=(4310 4311 4312 4313)
fi

PORT=""
reusando=0
for p in "${candidatas[@]}"; do
  if ! porta_tem_listener "$p"; then PORT="$p"; break; fi
  if proxy_compativel "$p"; then PORT="$p"; reusando=1; break; fi

  pid="$(pid_na_porta "$p")"
  if eh_nosso_proxy "$pid" && ! http_ok "$p" 5; then
    echo "Proxy claude-nvidia TRAVADO na porta $p (pid $pid não responde) — reiniciando..." >&2
    kill -9 "$pid" 2>/dev/null || true   # SIGKILL: nem sinal comum age sobre processo parado
    sleep 1
    if ! porta_tem_listener "$p"; then PORT="$p"; break; fi
    echo "  a porta $p não liberou; testando a próxima..." >&2
    continue
  fi
  echo "Porta $p ocupada por outro serviço (pid ${pid:-desconhecido}); testando a próxima..." >&2
done

if [ -z "$PORT" ]; then
  echo "Nenhuma porta utilizável em: ${candidatas[*]}" >&2
  echo "Feche a outra sessão do claude-nvidia ou rode com CLAUDE_NVIDIA_PORT=<porta>." >&2
  exit 1
fi

LOG="$CONFIG_DIR/litellm-$PORT.log"

if [ "$reusando" = 1 ]; then
  echo "Reusando proxy LiteLLM já rodando na porta $PORT (mesma config)."
else
  : >"$LOG"
  "$VENV_DIR/bin/litellm" --config "$CONFIG_DIR/config.yaml" --port "$PORT" >>"$LOG" 2>&1 &
  proxy_pid=$!

  echo "Iniciando proxy LiteLLM (porta $PORT)..."
  espera=0
  until curl -fs --max-time 2 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1; do
    espera=$((espera + 1))
    if [ "$espera" -gt 60 ]; then
      echo "O proxy não ficou pronto em 60s. Log: $LOG" >&2
      tail -n 20 "$LOG" >&2
      exit 1
    fi
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      echo "O proxy caiu. Veja o log: $LOG" >&2
      tail -n 20 "$LOG" >&2
      exit 1
    fi
    if [ $((espera % 5)) -eq 0 ]; then
      echo "  aguardando o proxy subir... ${espera}s" >&2
    fi
    sleep 1
  done
  echo "  proxy pronto em ${espera}s"

  if ! proxy_compativel "$PORT"; then
    echo "Proxy subiu mas não registrou $NV_MODEL. Log: $LOG" >&2
    tail -n 20 "$LOG" >&2
    exit 1
  fi
fi

# Smoke test com a NVIDIA: erro de configuração (chave/modelo) aborta;
# lentidão/instabilidade do endpoint hosted só gera aviso (o Claude Code retenta).
if [ "${CLAUDE_NVIDIA_SKIP_SMOKE:-0}" != "1" ]; then
  echo "Testando o endpoint da NVIDIA (até 45s, pode ser lento)..." >&2
  smoke_body="$(mktemp)"
  smoke_code="$(curl -sS --max-time 45 -o "$smoke_body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/v1/messages" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"responda: ok\"}]}" 2>/dev/null)" || true
  case "$smoke_code" in
    200) ;;
    400|401|403|404)
      echo "Erro de configuração ao falar com a NVIDIA (HTTP $smoke_code):" >&2
      head -c 800 "$smoke_body" >&2; echo >&2
      echo "Log: $LOG" >&2
      rm -f "$smoke_body"
      exit 1
      ;;
    *)
      echo "Aviso: a NVIDIA não respondeu em 45s (HTTP ${smoke_code:-000})." >&2
      echo "O endpoint hosted está lento/instável agora; o Claude Code vai retentar." >&2
      ;;
  esac
  rm -f "$smoke_body"
fi

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$SMALL_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SMALL_MODEL"
# Janela de contexto assumida pelo Claude Code (o modelo não está no catálogo dele).
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_NVIDIA_CONTEXT_TOKENS:-200000}"

claude "$@"
WRAP
sed -i "s|@HOME@|$PREFIX|g" "$WRAPPER"
chmod 755 "$WRAPPER"
ok "wrapper em $WRAPPER"

# ----------------------------------------------------------------- settings.json
# Só mexe em modelPicker.options (acrescenta/atualiza as nossas linhas);
# hooks e o resto do arquivo ficam intactos.
MODEL_PICKER_ROWS='[
  {"model":"nvidia-model","label":"NVIDIA principal (NV_MODEL)","description":"Modelo padrão do claude-nvidia (Nemotron 3 Super 120B)","behavesAs":"claude-sonnet-4-6"},
  {"model":"nvidia-k3","label":"NVIDIA Kimi-K3","description":"moonshotai/kimi-k3 — agentic, 1M de contexto","behavesAs":"claude-sonnet-4-6"},
  {"model":"nvidia-glm","label":"NVIDIA GLM-5.3","description":"z-ai/glm-5.3 — coding, 1M de contexto","behavesAs":"claude-sonnet-4-6"},
  {"model":"nvidia-nemotron","label":"NVIDIA Nemotron 3 Super 120B","description":"nvidia/nemotron-3-super-120b-a12b — rápido","behavesAs":"claude-sonnet-4-6"},
  {"model":"nvidia-small","label":"NVIDIA GPT-OSS 20B","description":"openai/gpt-oss-20b — tarefas de fundo","behavesAs":"claude-haiku-4-5"}
]'
printf '%s' "$MODEL_PICKER_ROWS" | SETTINGS_FILE="$SETTINGS" python3 -c '
import json, os, sys
rows = json.load(sys.stdin)
path = os.environ["SETTINGS_FILE"]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        print("settings.json invalido; abortando", file=sys.stderr); sys.exit(1)
opts = data.setdefault("modelPicker", {}).setdefault("options", [])
idx = {o.get("model"): i for i, o in enumerate(opts)}
for r in rows:
    if r["model"] in idx:
        opts[idx[r["model"]]] = r
    else:
        opts.append(r)
data["model"] = "nvidia-model"
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
'
ok "modelPicker em $SETTINGS ($(SETTINGS_FILE="$SETTINGS" python3 -c 'import json,os;print(len(json.load(open(os.environ["SETTINGS_FILE"]))["modelPicker"]["options"]))') opções)"

# ------------------------------------------------------------------------ PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR já está no PATH" ;;
  *)
    grep -q "$BIN_DIR" "$PREFIX/.profile" 2>/dev/null \
      || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$PREFIX/.profile"
    aviso "adicione ao PATH desta sessão: export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

# --------------------------------------------------------------------- validação
log "validando"
bash -n "$WRAPPER" || erro "sintaxe do wrapper inválida"
command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning "$WRAPPER" || true
python3 -c "import json,os;json.load(open('$SETTINGS'))" || erro "settings.json inválido"
"$VENV_DIR/bin/python" -c "
import yaml,sys
d=yaml.safe_load(open('$CONF'))
assert d.get('model_list'), 'model_list vazio'
print('   modelos:', ', '.join(m['model_name'] for m in d['model_list']))
" || erro "config.yaml inválido"

if [ "$DO_TEST" = 1 ]; then
  if command -v claude >/dev/null 2>&1; then
    log "teste: claude-nvidia --version (sobe o proxy e limpa)"
    out="$(CLAUDE_NVIDIA_SKIP_SMOKE=1 "$WRAPPER" --version 2>&1 | tail -n 4)" || erro "teste falhou: $out"
    printf '%s\n' "$out" | sed 's/^/   /'
    ok "wrapper + proxy OK"
  else
    log "teste: subindo o proxy direto"
    PORT=4399
    "$VENV_DIR/bin/litellm" --config "$CONF" --port $PORT >"$CONFIG_DIR/litellm-test.log" 2>&1 &
    TP=$!
    for _ in $(seq 1 45); do curl -fs --max-time 2 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 1; done
    curl -fs --max-time 5 -H "Authorization: Bearer $(set +e; source "$ENVF" >/dev/null 2>&1; printf %s "$LITELLM_MASTER_KEY")" \
      "http://127.0.0.1:$PORT/v1/models" | grep -q nvidia-model || { kill $TP; erro "proxy não registrou os modelos (ver $CONFIG_DIR/litellm-test.log)"; }
    kill $TP 2>/dev/null; wait $TP 2>/dev/null || true
    ok "proxy sobe e registra os modelos"
  fi
fi

if [ "$DO_E2E" = 1 ]; then
  log "teste ponta a ponta (claude -p)"
  "$WRAPPER" -p "responda apenas: ok" | tail -n 2
fi

echo
ok "instalado. Use: claude-nvidia"
echo "  modelo principal : $(set +e; source "$ENVF" >/dev/null 2>&1; echo "${NV_MODEL#nvidia_nim/}")  (troque NV_MODEL em $ENVF)"
echo "  trocar na hora   : /model  -> nvidia-model | nvidia-k3 | nvidia-glm | nvidia-nemotron | nvidia-small"
echo "  por chamada      : NV_MODEL=nvidia_nim/z-ai/glm-5.3 claude-nvidia"
