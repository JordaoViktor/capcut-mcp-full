# Epidemic Sound: MCP oficial e integração com CapCut

## MCP oficial (configurado no Codex)

O servidor remoto oficial está cadastrado como `epidemic-sound` no Codex,
com autenticação OAuth concluída pela conta do Epidemic Sound. Essa conexão
não precisa da chave da Partner API usada pela integração descrita abaixo.

Endereço oficial: `https://www.epidemicsound.com/a/mcp-service/mcp`.

Para cadastrar em outra instalação do Codex:

```sh
codex mcp add epidemic-sound --url https://www.epidemicsound.com/a/mcp-service/mcp
```

Conclua o login no navegador. Para autenticar novamente uma configuração existente:

```sh
codex mcp login epidemic-sound
```

A configuração fica em `~/.codex/config.toml`; as credenciais OAuth são
administradas pelo Codex. Inicie uma nova sessão ou recarregue a conexão MCP
para que o assistente carregue as ferramentas recém-adicionadas.

Fluxo com o CapCut: buscar e selecionar o áudio no MCP oficial, obter a URL
com a ferramenta de download, salvar o arquivo localmente e usar `add_clip`
do CapCut MCP com o caminho absoluto. O servidor remoto não escreve diretamente
nos projetos locais do CapCut. Acesso e downloads dependem da conta do provedor.

Referências: [MCP oficial do Epidemic Sound](https://developers.epidemicsound.com/docs/mcp/)
e [MCP no Codex](https://developers.openai.com/codex/mcp/).

## Integração alternativa pela Partner API

O servidor integra a **Partner API oficial** para buscar músicas e efeitos sonoros,
baixar o MP3 selecionado e adicioná-lo a um projeto do CapCut. Não exige outro MCP
nem uma nova dependência. As ferramentas existentes continuam funcionando sem chave.

## Configuração

1. Obtenha uma chave da Partner API no [portal de desenvolvedores](https://developers.epidemicsound.com/).
2. Acrescente ao `.env` da raiz deste projeto, preservando as variáveis existentes:

   ```dotenv
   EPIDEMIC_SOUND_API_KEY=sua_chave_da_partner_api
   ```

3. Reconstrua o servidor depois de atualizar o código:

   ```sh
   MIX_ENV=prod mix release --overwrite
   ```

4. Reinicie a conexão MCP. O `start-mcp.sh` lê o `.env` automaticamente.
   Se iniciar via `mix` ou no Windows, passe a variável no ambiente do processo.

O arquivo [.env.example](../.env.example) contém as opções, sem segredos.
`EPIDEMIC_SOUND_USER_ID` é opcional: use um identificador estável e anônimo para
atribuir as chamadas ao editor. `EPIDEMIC_SOUND_OUTPUT_DIR` define o diretório de
download quando não há projeto; o padrão é `epidemic-sound-output/` no diretório
de trabalho do servidor. Com projeto, o padrão é `<projeto>/epidemic-sound/`.

**A chave do MCP do Epidemic Sound, criada em `/account/api-keys`, é diferente da
chave da Partner API.** Esta implementação usa a segunda, com autenticação Bearer
no servidor. Uma assinatura do site não configura automaticamente essa integração.
Veja a [autenticação oficial](https://developers.epidemicsound.com/docs/auth/).

O acesso ao catálogo, os downloads e o uso comercial dependem do plano da API.
O plano gratuito de desenvolvimento é para protótipos e não inclui licença comercial,
conforme a [documentação de acesso](https://developers.epidemicsound.com/docs/).

## Buscar músicas e efeitos

Chame `search_epidemic_sound`:

```json
{
  "query": "upbeat corporate",
  "kind": "music",
  "vocal_type": "NONE",
  "limit": 5,
  "offset": 0
}
```

A resposta preserva os IDs, títulos, artistas, duração e demais metadados disponíveis,
incluindo `isPreviewOnly`, além de paginação. O campo `length` mantém a unidade da API
(segundos); os argumentos da timeline usam milissegundos. Para a próxima página,
aumente `offset` pelo `limit`. O máximo por chamada é 60.

Para efeitos, use `kind: "sound_effect"`, por exemplo `query: "short whoosh"`.
`vocal_type` só se aplica a músicas: `NONE` seleciona instrumentais, `LEAD` vozes
principais e `PRESENCE` elementos vocais. Não há download durante a busca.

## Baixar e adicionar ao projeto

Depois de selecionar um ID real da busca, chame `download_epidemic_sound`:

```json
{
  "track_id": "ID_RETORNADO_PELA_BUSCA",
  "kind": "music",
  "project_id": "ID_DO_PROJETO",
  "start_ms": 0,
  "duration_ms": 15000,
  "quality": "high"
}
```

- `quality`: `normal` (128 kbps, padrão) ou `high` (320 kbps).
- Sem `project_id`, apenas salva o arquivo e retorna seu caminho.
- Sem `duration_ms`, usa a duração estimada do MP3. Uma duração maior que a fonte
  é limitada à duração da fonte; o áudio não é esticado nem repetido.
- `output_path` pode indicar um novo caminho absoluto terminado em `.mp3`.
  Arquivos existentes nunca são sobrescritos.
- O resultado inclui o ID do segmento quando o áudio entra na timeline.
  Use `set_clip_volume` para ajustar o volume sob a narração, `trim_clip` para
  selecionar outro trecho e `set_clip_keyframe` para fades de volume.

Cada chamada bem-sucedida ao endpoint de download conta para o plano da API.
Reutilize um arquivo já baixado com `add_clip` em vez de baixá-lo novamente.
Não há tentativas automáticas que possam duplicar downloads.

Se o arquivo for salvo, mas a edição falhar, o resultado informa o caminho e
explica que o áudio **não foi adicionado**. Reutilize esse arquivo com `add_clip`.

## Depois da exportação

O provedor solicita o relato das exportações concluídas que contêm músicas.
Após exportar pelo CapCut ou obter sucesso com `render_project`, chame
`report_epidemic_sound_export` uma vez para essa exportação:

```json
{
  "track_ids": ["ID_DA_MUSICA_UTILIZADA"],
  "platform": "LOCAL"
}
```

Use `LOCAL` para o vídeo salvo no computador. Também são aceitos `YOUTUBE`,
`INSTAGRAM`, `TIKTOK`, `FACEBOOK`, `TWITCH`, `TWITTER` e `OTHER`.
Informe apenas as músicas realmente usadas; não relate efeitos sonoros,
pré-visualizações ou downloads de áudio. A ferramenta envia o evento ao provedor;
não publica o vídeo nem concede uma licença. Esse relato é uma etapa explícita:
o servidor não monitora exportações feitas pela interface do CapCut, e
`render_project` não chama essa ferramenta automaticamente.
Veja [contagem e relato de uso](https://developers.epidemicsound.com/docs/report-usage/).

## Verificação

```sh
mix test test/capcut_mcp/tools/epidemic_sound_test.exs
```

Os testes simulam a API: busca, paginação, autenticação, download, gravação de MP3,
edição de um projeto temporário, relato de exportação e falhas. Não gastam downloads.
A validação com catálogo real exige a chave configurada e acesso ao plano apropriado.
