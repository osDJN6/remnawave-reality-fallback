#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deploy-all.py — Автодеплой REALITY Fallback (Windows / Mac / Linux)

Требования:
    pip install paramiko pyyaml

Использование:
    1. Заполни config.yaml
    2. python deploy-all.py
"""

import os
import re
import sys
import secrets

try:
    import paramiko
except ImportError:
    print("Ошибка: установи paramiko командой:  pip install paramiko pyyaml")
    sys.exit(1)

try:
    import yaml
except ImportError:
    print("Ошибка: установи pyyaml командой:  pip install paramiko pyyaml")
    sys.exit(1)

# Устанавливаем UTF-8 для вывода (важно на Windows)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# Включаем ANSI цвета на Windows (cmd.exe / PowerShell)
if sys.platform == "win32":
    try:
        import ctypes
        ctypes.windll.kernel32.SetConsoleMode(ctypes.windll.kernel32.GetStdHandle(-11), 7)
    except Exception:
        pass

# ================================================================
# Загружаем конфигурацию из config.yaml
# ================================================================

_cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yaml")
if not os.path.isfile(_cfg_path):
    print(f"Ошибка: файл конфигурации не найден: {_cfg_path}")
    sys.exit(1)

with open(_cfg_path, encoding="utf-8") as _f:
    _cfg = yaml.safe_load(_f)

SNI_DONOR     = str(_cfg.get("sni_donor", "www.microsoft.com"))
FALLBACK_PORT = int(_cfg.get("fallback_port", 8080))
NODE_API_PORT = int(_cfg.get("node_api_port", 2222))
PANEL_IP      = str(_cfg.get("panel_ip", ""))
NODES         = _cfg.get("nodes", [])

# ================================================================

R = "\033[0;31m"; G = "\033[0;32m"; Y = "\033[1;33m"
C = "\033[0;36m"; NC = "\033[0m"

def info(msg):  print(f"{G}[INFO]{NC} {msg}", flush=True)
def warn(msg):  print(f"{Y}[WARN]{NC} {msg}", flush=True)
def error(msg): print(f"{R}[ERROR]{NC} {msg}", flush=True)
def step(msg):  print(f"\n{C}━━━ {msg} ━━━{NC}", flush=True)


def ssh_connect(ip, user, password):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        ip, username=user, password=password,
        timeout=15, allow_agent=False, look_for_keys=False
    )
    return client


def ssh_run(client, cmd, stream=False):
    """Выполнить команду. stream=True — выводить построчно в реальном времени."""
    stdin, stdout, stderr = client.exec_command(cmd, get_pty=stream)

    out_lines = []
    if stream:
        for raw_line in stdout:
            line = raw_line.decode("utf-8", errors="replace") if isinstance(raw_line, bytes) else raw_line
            line = line.rstrip("\r\n")
            print(line, flush=True)
            out_lines.append(line)
    else:
        raw = stdout.read()
        out_lines = (raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw).splitlines()

    exit_code = stdout.channel.recv_exit_status()
    return exit_code, "\n".join(out_lines)


def upload_file(client, local_path, remote_path):
    sftp = client.open_sftp()
    sftp.put(local_path, remote_path)
    sftp.chmod(remote_path, 0o755)
    sftp.close()


def gen_keys_xray(client):
    code, out = ssh_run(client, "docker exec remnanode xray x25519 2>/dev/null || docker exec remnanode /usr/local/bin/xray x25519 2>/dev/null")
    if code == 0 and "Private key:" in out:
        priv = next((l.split()[-1] for l in out.splitlines() if "Private key:" in l), "")
        pub  = next((l.split()[-1] for l in out.splitlines() if "Public key:"  in l), "")
        return priv, pub
    return None, None


def gen_keys_openssl(client):
    cmd = (
        "PRIV_PEM=$(openssl genpkey -algorithm X25519 2>/dev/null); "
        "PRIV=$(echo \"$PRIV_PEM\" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\\n'); "
        "PUB=$(echo \"$PRIV_PEM\"  | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\\n'); "
        "echo \"PRIVATE_KEY=$PRIV\"; echo \"PUBLIC_KEY=$PUB\""
    )
    _, out = ssh_run(client, cmd)
    priv = next((l.split("=", 1)[1] for l in out.splitlines() if l.startswith("PRIVATE_KEY=")), "").strip()
    pub  = next((l.split("=", 1)[1] for l in out.splitlines() if l.startswith("PUBLIC_KEY=")),  "").strip()
    return priv, pub


def validate_config():
    if not re.match(r'^[a-zA-Z0-9.\-]+$', SNI_DONOR):
        error(f"SNI_DONOR содержит недопустимые символы: '{SNI_DONOR}'")
        sys.exit(1)
    if not (1 <= FALLBACK_PORT <= 65535):
        error("FALLBACK_PORT должен быть числом от 1 до 65535")
        sys.exit(1)
    if not (1 <= NODE_API_PORT <= 65535):
        error("NODE_API_PORT должен быть числом от 1 до 65535")
        sys.exit(1)
    if not NODES:
        error("Список NODES пустой — заполни конфигурацию в начале скрипта")
        sys.exit(1)
    for node in NODES:
        for key in ("label", "ip", "user", "password"):
            if not node.get(key):
                error(f"В одной из записей NODES не заполнено поле '{key}'")
                sys.exit(1)


def main():
    validate_config()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    deploy_sh  = os.path.join(script_dir, "deploy.sh")

    if not os.path.isfile(deploy_sh):
        error(f"deploy.sh не найден: {deploy_sh}")
        sys.exit(1)

    ok_nodes   = []
    fail_nodes = []
    key_client = None   # первая успешная нода — для генерации ключей

    # ── Деплой на каждую ноду ────────────────────────────────
    for node in NODES:
        label = node["label"]
        ip    = node["ip"]
        user  = node["user"]
        pwd   = node["password"]

        step(f"Нода: {label} ({ip})")

        client = None
        try:
            info(f"[{label}] Подключаюсь...")
            client = ssh_connect(ip, user, pwd)
            info(f"[{label}] Подключён — OK")

            info(f"[{label}] Копирую deploy.sh...")
            upload_file(client, deploy_sh, "/tmp/remnawave-deploy.sh")

            info(f"[{label}] Запускаю деплой...")
            env_cmd = (
                f"SNI_DONOR='{SNI_DONOR}' "
                f"FALLBACK_PORT='{FALLBACK_PORT}' "
                f"NODE_API_PORT='{NODE_API_PORT}' "
                f"PANEL_IP='{PANEL_IP}' "
                f"bash /tmp/remnawave-deploy.sh"
            )
            code, _ = ssh_run(client, env_cmd, stream=True)

            if code != 0:
                error(f"[{label}] Деплой завершился с ошибкой (код {code})")
                fail_nodes.append(f"  {R}✗{NC}  {label} ({ip}) — ошибка деплоя (код {code})")
                client.close()
                continue

            info(f"[{label}] Деплой успешен")
            ok_nodes.append(f"  {G}✓{NC}  {label} ({ip})")

            if key_client is None:
                key_client = client   # оставляем соединение для генерации ключей
            else:
                client.close()

        except Exception as exc:
            error(f"[{label}] Ошибка: {exc}")
            fail_nodes.append(f"  {R}✗{NC}  {label} ({ip}) — {exc}")
            if client:
                try:
                    client.close()
                except Exception:
                    pass

    # ── Генерация x25519 ключей ───────────────────────────────
    step("Генерация x25519 ключей")

    priv_key = pub_key = short_id = ""

    if key_client:
        try:
            priv_key, pub_key = gen_keys_xray(key_client)
            if priv_key:
                info("Ключи получены через xray (remnanode)")
            else:
                warn("remnanode не запущен — генерирую через openssl")
                priv_key, pub_key = gen_keys_openssl(key_client)
                if priv_key:
                    info("Ключи сгенерированы через openssl")

            _, short_id = ssh_run(key_client, "openssl rand -hex 4")
            short_id = short_id.strip()
        except Exception as exc:
            warn(f"Ошибка при генерации ключей: {exc}")
        finally:
            key_client.close()

    if not priv_key:
        warn("Сгенерируй ключи вручную: docker exec remnanode /usr/local/bin/xray x25519")
        priv_key = "ВСТАВЬ_PRIVATE_KEY"
        pub_key  = "ВСТАВЬ_PUBLIC_KEY"

    if not short_id:
        short_id = secrets.token_hex(4)

    # ── Итог ─────────────────────────────────────────────────
    line = "═" * 56
    print(f"\n{C}{line}{NC}")
    print(f"{G}  ИТОГ{NC}")
    print(f"{C}{line}{NC}\n")
    for ln in ok_nodes:
        print(ln)
    for ln in fail_nodes:
        print(ln)

    print(f"\n{C}{'═' * 18} Config Profile {'═' * 19}{NC}")
    print(f"{Y}  Один профиль — для всех нод{NC}\n")
    print(f"  privateKey: {G}{priv_key}{NC}")
    print(f"  publicKey:  {G}{pub_key}{NC}")
    print(f"  shortId:    {G}{short_id}{NC}")
    print(f"  SNI:        {G}{SNI_DONOR}{NC}")
    print(f"\n  Вставь JSON ниже: Xray config → Config Profiles → New\n")

    print(f"""\
{{
  "log": {{
    "loglevel": "none"
  }},
  "dns": {{
    "servers": [
      "https+local://8.8.8.8",
      "https+local://1.1.1.1"
    ],
    "queryStrategy": "UseIPv4"
  }},
  "inbounds": [
    {{
      "tag": "VLESS-REALITY",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {{
        "clients": [],
        "decryption": "none",
        "fallbacks": [
          {{ "dest": {FALLBACK_PORT}, "xver": 0 }}
        ]
      }},
      "sniffing": {{
        "enabled": false,
        "routeOnly": true,
        "destOverride": ["http", "tls", "quic", "fakedns"]
      }},
      "streamSettings": {{
        "network": "raw",
        "security": "reality",
        "realitySettings": {{
          "show": false,
          "xver": 0,
          "target": "{SNI_DONOR}:443",
          "serverNames": ["{SNI_DONOR}"],
          "privateKey": "{priv_key}",
          "shortIds": ["{short_id}"],
          "fingerprint": "firefox"
        }}
      }}
    }}
  ],
  "outbounds": [
    {{
      "tag": "DIRECT",
      "protocol": "freedom"
    }},
    {{
      "tag": "BLOCK",
      "protocol": "blackhole"
    }}
  ],
  "routing": {{
    "rules": [
      {{
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      }},
      {{
        "ip": ["geoip:private"],
        "type": "field",
        "outboundTag": "BLOCK"
      }},
      {{
        "type": "field",
        "domain": ["geosite:private"],
        "outboundTag": "BLOCK"
      }}
    ]
  }}
}}""")

    print(f"\n{C}{'═' * 18} Host настройки {'═' * 21}{NC}\n")
    print(f"  address   = IP ноды")
    print(f"  port      = 443")
    print(f"  security  = tls")
    print(f"  sni       = {G}{SNI_DONOR}{NC}")
    print(f"  fp        = firefox")
    print(f"  publicKey = {G}{pub_key}{NC}")
    print(f"  shortId   = {G}{short_id}{NC}")
    print(f"\n{C}{line}{NC}")


if __name__ == "__main__":
    main()
