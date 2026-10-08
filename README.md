# claude-nvidia

Faz o **Claude Code** rodar com modelos da **NVIDIA NIM** (Nemotron 3 Super por padrão; também Kimi-K3, GLM-5.3, GPT-OSS...)
através de um proxy LiteLLM local. Um único instalador idempotente configura tudo.

## Instalação

```bash
git clone https://github.com/rodriguesfas/claude-nvidia.git
cd claude-nvidia
chmod +x install-nvidia-claude-code.sh
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install-nvidia-claude-code.sh
```

Sem a env var, ele pergunta a chave (fica salva com permissão `600`).
Pegue a chave em <https://build.nvidia.com>.

Ou em uma linha (baixa e roda direto):

```bash
curl -fsSL https://raw.githubusercontent.com/rodriguesfas/claude-nvidia/main/install-nvidia-claude-code.sh -o install-nvidia-claude-code.sh
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install-nvidia-claude-code.sh
```

**Requisitos:** Linux, `python3`, `curl`, `ss` e o [Claude Code](https://docs.anthropic.com/claude/code)
(`npm i -g @anthropic-ai/claude-code`).

## O que ele instala

| Caminho | O que é |
|---|---|
| `~/.claude-nvidia/venv` | venv com `litellm[proxy]==1.104.0` |
| `~/.config/claude-nvidia/env` | chave NVIDIA, master key do proxy, modelos (`600`) |
| `~/.config/claude-nvidia/config.yaml` | modelos registrados no proxy |
| `~/.local/bin/claude-nvidia` | wrapper: sobe o proxy, roda o Claude Code, encerra ao sair |
| `~/.claude/settings.json` | só acrescenta as opções em `modelPicker.options` (hooks/theme intactos) |

Repetir a execução é seguro: **preserva** chave, master key, modelos já gravados e o resto do `settings.json`.

## Uso

```bash
claude-nvidia
```

### Trocar o modelo

1. **Padrão** — edite `NV_MODEL` em `~/.config/claude-nvidia/env`
   (padrão `nvidia_nim/nvidia/nemotron-3-super-120b-a12b` — Nemotron 3 Super)
2. **Por chamada** — `NV_MODEL=nvidia_nim/z-ai/glm-5.3 claude-nvidia`
3. **Dentro da sessão** — `/model` → `nvidia-model` · `nvidia-k3` · `nvidia-glm` · `nvidia-nemotron` · `nvidia-small`

Lista de modelos disponíveis: `GET https://integrate.api.nvidia.com/v1/models`.

### Flags do instalador

| Flag | Efeito |
|---|---|
| `NVIDIA_NIM_API_KEY=...` | chave sem prompt (preferível a `--api-key`, que aparece no `ps`) |
| `--model`, `--small-model` | muda o modelo padrão gravado no `env` |
| `--no-test` | não sobe o proxy na validação |
| `--e2e` | além da validação, roda um `claude -p` de ponta a ponta |

## Como funciona

- O wrapper sobe o proxy LiteLLM nas portas `4310`–`4313` (`CLAUDE_NVIDIA_PORT` sobrescreve)
  e **encerra só o proxy que ele mesmo criou** ao sair.
- Reusa um proxy existente apenas se a config dele for **atual** (compara `model/porta`
  via `GET /v1/model/info`); config antiga é ignorada e outro sobe numa porta seguinte,
  sem derrubar a sessão que está usando.
- Detecção de porta é **TCP (`ss`)**, não HTTP: um proxy parado (ex.: sessão com `Ctrl+Z`)
  é reconhecido como *travado* e reiniciado com `kill -9` — era isso que fazia o
  "Iniciando proxy LiteLLM" travar para sempre.
- Todo `curl` tem `--max-time`; o boot imprime progresso (12–40s) e o smoke test avisa
  antes de falar com a NVIDIA (timeout vira aviso, não erro — o Claude Code retenta).

## Problemas

- **Fica em "Iniciando proxy..."** — atualize para a versão com probe TCP (esta);
  veja `~/.config/claude-nvidia/litellm-4310.log`.
- **`Erro de configuração ao falar com a NVIDIA (HTTP 401)`** — chave inválida/em falta:
  edite `~/.config/claude-nvidia/env`.
- **Processos sobrando** — `ps -eo pid,stat,args | grep claude-nvidia` e `kill -9 <pids>`.
- **Endpoint lento/instável** — `integrate.api.nvidia.com` tem timeouts intermitentes;
  o wrapper só avisa e o Claude Code retenta (`CLAUDE_NVIDIA_SKIP_SMOKE=1` pula o teste).
