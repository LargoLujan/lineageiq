# MCP remoto (Streamable HTTP) — conectar Claude, ChatGPT, y otros agentes

## Qué es esto

Este servidor expone su catálogo de linaje (workspaces, dependencias, impacto de objetos, estado de escaneos, roles de acceso, historial de ejecuciones y más) como un servidor MCP real, alcanzable por **una sola URL pública**:

```
https://<el mismo dominio donde ya ves el visor>/mcp
```

No hace falta instalar nada, ni descargar ningún script, ni tener el repositorio en ningún sitio — cualquier cliente MCP que sepa añadir un conector remoto por URL puede usarlo directamente. Esto es lo que hace falta para que un producto de IA **hospedado** (ChatGPT, Claude en la web, etc.) pueda conectarse: esos productos no pueden lanzar un proceso en tu máquina, solo alcanzar una URL.

Implementación: `backend/scripts/mcp_http_server.py`, un subproceso que `lineage_web_server.py` arranca automáticamente (puerto interno, nunca expuesto directamente), con `backend/scripts/lineage_web/handler.py` haciendo de proxy inverso desde `/mcp` en el puerto público. Transporte: **Streamable HTTP**, el transporte remoto estándar del protocolo MCP.

## Autenticación

Un token Bearer — exactamente la misma API key que ya se crea desde el panel de administración, pestaña **API keys**. Cada llamada (incluida la primera, `initialize`) exige la cabecera:

```
Authorization: Bearer <tu-api-key>
```

Sin ella, o con una clave inválida/caducada/revocada, el servidor responde `401`. No hay flujo OAuth — es una clave estática de larga duración, más simple de configurar para un despliegue propio como este; si en el futuro se necesitara OAuth real (por ejemplo, para que cada persona tenga su propia identidad en vez de compartir una clave), sería un cambio bastante más grande y no está construido.

## Por proveedor

Lo único realmente estable aquí es "URL + token Bearer" — el protocolo MCP en sí. Las pantallas concretas de cada producto cambian con el tiempo; lo de abajo es lo verificado o lo más razonable a la fecha de esta nota (2026-08-24), no una promesa de que el clic-a-clic no haya cambiado.

### Claude Code (CLI)

Verificado el patrón general del comando (no la versión exacta instalada en cada máquina):

```bash
claude mcp add --transport http fabric-lineage https://<tu-dominio>/mcp --header "Authorization: Bearer <tu-api-key>"
```

Si tu versión de `claude mcp add` no reconoce `--transport http` o `--header`, ejecuta `claude mcp add --help` para ver los flags que sí acepta esa versión.

### Claude Desktop / claude.ai (conectores)

Ajustes → Conectores (o "Connectors") → Añadir un conector personalizado → pega la URL (`https://<tu-dominio>/mcp`) y, si la interfaz lo pide, la cabecera `Authorization: Bearer <tu-api-key>`. Si esa versión concreta de la interfaz no ofrece un campo de cabecera personalizada para conectores remotos, usa la vía de Claude Code de arriba en su lugar.

### ChatGPT (Connectors / Apps)

Ajustes → Connectors (o Apps, según la cuenta) → Añadir conector personalizado → URL del servidor MCP (`https://<tu-dominio>/mcp`) y la cabecera de autenticación cuando la pida. La disponibilidad de "conectores personalizados por URL" depende del tipo de cuenta/plan.

### Cursor

`~/.cursor/mcp.json` (o el equivalente por proyecto, `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "fabric-lineage": {
      "url": "https://<tu-dominio>/mcp",
      "headers": { "Authorization": "Bearer <tu-api-key>" }
    }
  }
}
```

### Windsurf

Mismo patrón que Cursor, en su propio archivo de configuración MCP (`~/.codeium/windsurf/mcp_config.json` en instalaciones recientes) con la misma forma `{"url": ..., "headers": {...}}`.

### GitHub Copilot (VS Code)

Copilot Chat en modo agente soporta servidores MCP remotos vía `.vscode/mcp.json` en el workspace, con la misma forma `url` + `headers`.

### Cualquier otro cliente compatible con MCP

Si el cliente no está en esta lista, busca en su documentación "MCP remote server", "Streamable HTTP", o "custom connector by URL" — si soporta añadir un servidor por URL con una cabecera personalizada, esta URL y este token funcionan igual que con cualquiera de los de arriba.

## Verificación rápida (sin cliente de IA)

```bash
curl -s -D - -X POST https://<tu-dominio>/mcp \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <tu-api-key>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}'
```

Una respuesta `200` con `event: message` y un `serverInfo` en el JSON confirma que el servidor está vivo y la clave es válida. Un `401` significa clave ausente/inválida. Un `503` significa que el subproceso `mcp_http_server.py` no arrancó (revisa el log de arranque del servidor; probablemente falte `pip install -r requirements-mcp.txt`).

## Qué NO es esto

- No sustituye a `backend/scripts/mcp_server.py` (local, lee archivos directamente, sin llamadas de red) ni a `backend/scripts/mcp_server_remote.py` (stdio, pero llamando a la REST API) — siguen existiendo para quien prefiera ejecutar el proceso MCP en su propia máquina. Ambos siguen documentados en el README.
- No implementa OAuth 2.1 completo (registro dinámico de clientes, emisión de tokens, etc.) — solo verificación de un token Bearer estático contra las claves ya emitidas desde el panel. Suficiente para "cualquier agente autenticado se puede conectar", no pensado para escenarios multi-tenant con identidades por usuario dentro del propio agente.
