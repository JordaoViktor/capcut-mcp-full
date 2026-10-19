# Guia de uso do MCP do CapCut para o time de Marketing

Este guia explica como o time de marketing usa o servidor **CapCut MCP** para criar, editar e renderizar vídeos por conversa, sem abrir o CapCut para cada ajuste.

O MCP expõe 28 ferramentas. Você não precisa decorar nomes: fale com o agente em português e ele escolhe a ferramenta certa. Este documento serve para entender o que é possível, quais informações passar e como evitar erros.

---

## 1. O que dá para fazer

- Listar e inspecionar projetos (drafts) do CapCut.
- Criar projetos verticais (Reels/Shorts), quadrados ou horizontais.
- Adicionar vídeos, imagens, áudios e textos na timeline.
- Cortar, mover, remover, girar, escalar, alterar opacidade e volume.
- Aplicar blend modes e animações por keyframe.
- Aplicar animações de entrada/saída em textos.
- Manter uma memória de marca (cores, tipografia, assinatura) e aplicá-la.
- Gerar vídeos com IA no Runway (MCP separado) e inserir o MP4 na timeline com `add_clip`.
- Gerar narração com ElevenLabs (TTS na nuvem).
- Transcrever áudios/vídeos e receber comandos por voz.
- Renderizar o projeto final em MP4/WebM/MOV.

---

## 2. Pré-requisitos

| Item | Para quê | Onde configurar |
|---|---|---|
| CapCut desktop instalado | Os projetos são os drafts locais do CapCut | App CapCut |
| MCP do CapCut conectado ao agente | Executar as ferramentas | Configuração do opencode/Claude |
| `RUNWAYML_API_SECRET` | MCP do Runway (`generate_video`) | `runway-mcp/.env` ou variável de ambiente |
| `GEMINI_API_KEY` | `transcribe_audio` e `voice_command` | `.env` ou variável de ambiente |
| `ELEVENLABS_API_KEY` | `generate_speech`, `list_voices`, `speak_reply` (provedor ElevenLabs) | `.env` ou variável de ambiente |
| Créditos no Runway | Gerar vídeos com IA | https://dev.runwayml.com |
| Node.js 18+ e `npm install` em `renderer/` | `render_project` | Pasta `renderer/` |

O servidor sobe mesmo sem chaves: cada ferramenta avisa qual chave falta quando é chamada.

---

## 3. Conceitos básicos

- **Projeto / draft**: é o projeto do CapCut. O identificador é o `project_id` (também chamado de `draft_id`), obtido com `list_projects`.
- **Timeline**: a linha do tempo. Tudo é medido em **milissegundos (ms)**. 3 segundos = `3000`.
- **Track**: a faixa da timeline. Vídeo/imagem ficam em tracks de vídeo; áudio em track de áudio; texto em track de texto.
- **Segmento / clip**: cada item na timeline tem um `clip_id` (segment ID), obtido com `get_timeline`.
- **Arquivo local**: `add_clip` e `transcribe_audio` recebem **caminho absoluto** de um arquivo que existe na máquina.
- **Imagem para vídeo**: o `generate_video` do MCP do Runway aceita URL HTTPS, data URI ou caminho local (até 5 MB).
- **Marca**: memória global em `~/.config/capcut-mcp/brand.json`, aplicada quando você usa `use_brand: true`.

Fluxo mental padrão:

```
list_projects  →  get_timeline  →  (add/move/trim/set...)  →  render_project
```

---

## 4. Como pedir ao agente

Fale em linguagem natural, informando **projeto**, **tempo** e **o que mudar**. Exemplos:

- "Liste meus projetos do CapCut."
- "Mostre a timeline do projeto `abc123`."
- "Crie um projeto vertical 1080x1920 a 30fps chamado `Reel Black Friday`."
- "Adicione o vídeo `/Users/time/Videos/gancho.mp4` no projeto `abc123` começando em 0ms por 6s."
- "Coloque o texto `50% OFF` no projeto `abc123`, de 1000ms a 4000ms, branco, tamanho 8, na parte de baixo."
- "Aplique fade-in nesse texto e fade-out no último segundo."
- "Deixe o clipe `seg-42` com opacidade 0.8 e volume 0.6."
- "Renderize o projeto `abc123` em MP4."

Dicas para o pedido sair certo:

1. Sempre informe o **nome ou id do projeto**.
2. Informe **tempos em ms** (ou diga "aos 2 segundos").
3. Para alterar um clipe, peça antes a timeline para o agente obter o `clip_id`.
4. Diga o **formato** desejado (9:16, 16:9, 1:1) e a **resolução**.
5. Para geração com IA, diga o **modelo** e o **custo máximo** que aceita.

---

## 5. Referência das ferramentas

### 5.1 Descoberta e inspeção

#### `list_projects`
Lista todos os drafts locais com nome, id, duração e última modificação.
- **Use quando**: precisa descobrir o `project_id`.
- **Pedido**: "Liste meus projetos."

#### `get_project`
Mostra configuração do projeto: largura, altura, FPS, duração e número de tracks.
- **Argumentos**: `project_id`.
- **Pedido**: "Qual o tamanho e o FPS do projeto `abc123`?"

#### `get_timeline`
Mostra todas as tracks, segmentos, timecodes e material IDs.
- **Argumentos**: `project_id`.
- **Use quando**: precisa do `clip_id` para cortar, mover, alterar etc.
- **Pedido**: "Mostre a timeline do projeto `abc123`."

#### `read_draft_json`
Retorna o JSON bruto do draft. É para depuração técnica.
- **Use quando**: o agente precisa investigar uma estrutura que não aparece na timeline.
- **Evite** no dia a dia; a saída é grande.

---

### 5.2 Criação e remoção de projetos

#### `create_project`
Cria um draft vazio com o scaffold completo do CapCut (abre de verdade no app).
- **Argumentos**: `name`; opcionais `width` (1920), `height` (1080), `fps` (30).
- **Formatos comuns**: 1080x1920 (Reels/Shorts), 1920x1080 (YouTube), 1080x1080 (feed).
- **Pedido**: "Crie um projeto 1080x1920, 30fps, chamado `Reel Promo`."

#### `remove_project`
Remove o projeto do manifesto e, por padrão, apaga a pasta em disco. **Ação destrutiva.**
- **Argumentos**: `project_id`; opcional `keep_files` (true mantém os arquivos).
- **Pedido**: "Remova o projeto `abc123`." (confirme antes)

---

### 5.3 Mídia na timeline

#### `add_clip`
Adiciona vídeo, áudio ou imagem à timeline.
- **Argumentos**: `project_id`, `file_path`; opcionais `start_ms` (0), `duration_ms` (5000), `track_index` (auto).
- **Extensões aceitas**:
  - Vídeo: `.mp4 .mov .avi .mkv .webm .m4v .wmv`
  - Áudio: `.mp3 .wav .aac .flac .ogg .m4a`
  - Imagem: `.png .jpg .jpeg .webp` (entram como camada de foto — logo, watermark, still)
- **Pedido**: "Adicione a imagem `/Users/time/logo.png` no projeto `abc123`, de 0 a 3000ms."

#### `trim_clip`
Define o trecho do arquivo-fonte usado e, se quiser, a duração na timeline.
- **Argumentos**: `project_id`, `clip_id`; opcionais `source_start_ms`, `source_duration_ms`, `target_duration_ms`.
- **Pedido**: "Corte o clipe `seg-42` a partir de 2s e use 4s."

#### `move_clip`
Move o clipe para outro instante da timeline, sem mudar duração.
- **Argumentos**: `project_id`, `clip_id`, `start_ms`.
- **Pedido**: "Mova o clipe `seg-42` para 5000ms."

#### `remove_clip`
Remove um segmento da timeline.
- **Argumentos**: `project_id`, `clip_id`.
- **Pedido**: "Remova o clipe `seg-42`."

---

### 5.4 Ajustes visuais e de áudio

Valores de posição usam a convenção do CapCut: `0.0` = centro, `-1.0` = borda superior/esquerda, `1.0` = borda inferior/direita.

#### `set_clip_transform`
Posição, escala e rotação de um clipe de vídeo/imagem.
- **Argumentos**: `project_id`, `clip_id`; opcionais `x`, `y`, `scale_x`, `scale_y` (1.0 = 100%), `rotation` (graus).
- **Pedido**: "Deixe o logo `seg-10` a 80% e no canto superior direito (`x: 0.6`, `y: -0.6`)."

#### `set_clip_opacity`
Transparência do clipe.
- **Argumentos**: `project_id`, `clip_id`, `opacity` (0.0 a 1.0).
- **Pedido**: "Opacidade 0.5 no clipe `seg-42`."

#### `set_clip_volume`
Volume do áudio (ou do áudio de um vídeo).
- **Argumentos**: `project_id`, `clip_id`, `volume` (0 = mudo, 1 = normal, >1 = boost).
- **Pedido**: "Deixe a música `seg-07` em 0.3 e mute o clipe `seg-42`."

#### `set_clip_loop`
Repete o clipe durante toda a duração na timeline.
- **Argumentos**: `project_id`, `clip_id`, `loop` (true/false).
- **Pedido**: "Ative o loop no clipe `seg-03`."

#### `set_clip_blend_mode`
Aplica modo de mesclagem (útil para overlays e luzes).
- **Argumentos**: `project_id`, `clip_id`, `mode`; opcional `value` (0.0–1.0, padrão 1.0).
- **Modos**: `soft_light`, `multiply_blend_mode`, `over_lay`, `glare_pc` (screen), `color_filter`, `dark_en`, `bright_en`, `linear_deepening`, `darken_color`, `color_dodge`.
- **Atalhos mentais**: `glare_pc` = screen (tirar preto), `multiply_blend_mode` = escurecer, `soft_light` = luz sutil, `over_lay` = contraste.
- **Pedido**: "Coloque o overlay `seg-09` em screen."

#### `set_clip_keyframe`
Cria animação de uma propriedade ao longo do tempo. Chame **uma vez por ponto**.
- **Argumentos**: `project_id`, `clip_id`, `property`, `time_offset_ms` (relativo ao início do clipe), `value`.
- **Propriedades**: `alpha`, `brightness`, `contrast`, `position_x`, `position_y`, `rotation`, `saturation`, `scale_x`, `scale_y`, `uniform_scale`, `volume`.
- **Exemplo de fade-in**: `alpha=0.0` em `0ms` e `alpha=1.0` em `500ms`.
- **Pedido**: "Faça o logo `seg-10` aparecer com fade-in de 500ms e crescer de 80% para 100%."

---

### 5.5 Texto e animações de texto

#### `add_text`
Adiciona overlay de texto.
- **Argumentos obrigatórios**: `project_id`, `content`, `start_ms`, `duration_ms`.
- **Opcionais**: `font_size` (percentual da altura do canvas; padrão 8.0), `color` (`#RRGGBB`, padrão `#FFFFFF`), `stroke_color`, `stroke_width` (0.08), `position_y` (-1 topo, 0 centro, 1 base), `use_brand` (bool), `track_index`.
- **Pedido**: "Adicione o texto `FRETE GRÁTIS` no projeto `abc123`, de 0 a 3000ms, amarelo, com contorno preto, na parte de baixo."
- **Com marca**: peça "use a identidade da marca" para o agente passar `use_brand: true`.

#### `add_text_animation`
Aplica animação de entrada ou saída em um texto já existente.
- **Argumentos**: `project_id`, `clip_id` (id do texto), `animation`; opcional `duration_ms`.
- **Pedido**: "Coloque fade-in no texto `seg-55` e fade-out no último segundo."

#### `list_text_animations`
Lista os nomes de animação disponíveis.
- **Animações curadas**:
  - Entrada: `fade_in`, `typewriter`, `slide_up`, `slide_left`, `blur_in`
  - Saída: `fade_out`, `slide_down`, `slide_right`, `blur_out`
- **Pedido**: "Quais animações de texto existem?"

---

### 5.6 Identidade de marca

A marca é uma memória global, fora dos drafts do CapCut, em `~/.config/capcut-mcp/brand.json`.

#### `get_brand`
Lê a marca global e os estilos pendentes do projeto.
- **Argumentos**: opcional `project_id`.
- **Pedido**: "Mostre a identidade da marca e o que está pendente no projeto `abc123`."

#### `set_brand`
Define/atualiza a marca global. É a **única entrada explícita**.
- **Argumentos**: `brand` (objeto), `mode` (`merge` padrão ou `replace`).
- **Formato livre**, com subárvore `paleta` validada:
  ```json
  {
    "empresa": { "nome": "Minha Marca", "tagline": "..." },
    "paleta": { "primaria": "#FFB13D", "texto": "#FFFFFF" },
    "tipografia": { "display": "Poppins", "titulo": 16 },
    "assinatura": { "posicao_y": 0.78 }
  }
  ```
- **Cores** em `paleta` devem ser `#RRGGBB`.
- **Pedido**: "Atualize a marca: primária `#FFB13D`, texto `#FFFFFF`, título Poppins 16."

#### `promote_style`
Promove estilos do projeto para a marca global (opt-in).
- **Sem `campo`/`valor`**: promove todas as pendências (cores ganham papéis como `paleta.acento`).
- **Com `campo`/`valor`**: define um caminho exato, ex. `campo: "paleta.acento"`, `valor: "#1E88E5"`.
- **Pedido**: "Promova as cores pendentes do projeto `abc123` para a marca."

Fluxo recomendado de marca:

```
set_brand  →  add_text (use_brand: true)  →  get_brand (revisar pendências)  →  promote_style
```

---

### 5.7 Geração de vídeo com IA (Runway MCP)

A geração de vídeo **não faz parte do MCP do CapCut**. Ela roda em um servidor MCP separado, em `runway-mcp/`, e o fluxo é sempre: gerar no Runway → receber o caminho absoluto do MP4 → inserir no CapCut com `add_clip`.

#### `generate_video` (MCP do Runway)
- **Argumentos**: `prompt` (obrigatório); opcionais `image`, `model`, `ratio`, `aspect_ratio` (`16:9`/`9:16`), `duration_seconds`, `seed`, `audio`, `negative_prompt`, `output_path`, `wait`, `timeout_ms`.
- **Padrões**: modelo `gen4.5`, ratio `1280:720`, 5s, saída em `~/Movies/runway/`.
- **Sem `wait`**: retorna o `task_id` na hora; consulte depois com `get_task` (e `download: true` para salvar).
- **Com imagem**: use `image` para image-to-video (URL pública, data URI ou caminho local).
- **Pedido**: "Gere um vídeo 9:16 de 5s no Runway mostrando o produto girando e adicione no projeto `abc123` aos 2s."

Modelos Runway disponíveis incluem `gen4.5`, `gen4_turbo`, `veo3.1`, `veo3.1_fast`, `seedance2`, `seedance2_5`, `kling3.0_pro`, `wan3`, entre outros. Rode `list_models` no MCP do Runway para ver a lista atual e o padrão configurado.

Regras práticas:

- Informe `duration_seconds` conforme o modelo (em geral 2–10s); o `gen4.5` exige duração e ratio.
- `audio` e `negative_prompt` só funcionam em modelos que suportam esses campos.
- Gerações levam de 30s a alguns minutos; aumente `timeout_ms` se necessário.
- Sem créditos a resposta é `402`; adicione créditos em https://dev.runwayml.com.
- O resultado inclui `File`, `Duration (ms)` e `Task ID`; use o caminho em `add_clip` e a duração em `duration_ms`.

---

### 5.8 Voz, narração e transcrição

#### `generate_speech`
Gera narração/voiceover com ElevenLabs (nuvem, MP3, requer `ELEVENLABS_API_KEY`) e, opcionalmente, adiciona à timeline.

**Argumentos**: `text`; opcionais `voice_id`/`voice_name` (ex. "Rachel"), `project_id`, `start_ms`, `track_index`, `duration_ms`, `output_path`, `model_id` (`eleven_multilingual_v2`), `stability` (0.5), `similarity_boost` (0.75), `style` (0), `speed` (0.7–1.2, padrão 1.0).

- **Pedido ElevenLabs**: "Gere uma narração dizendo `Chega de desculpas.` com a voz Rachel e adicione aos 2s do projeto `abc123`."

#### `list_voices`
Lista as vozes da conta ElevenLabs (id + nome). Requer `ELEVENLABS_API_KEY`.
- **Pedido**: "Quais vozes estão disponíveis?"

#### `transcribe_audio`
Transcreve áudio ou vídeo com Gemini (até ~15 MB).
- **Argumentos**: `file_path`; opcionais `model` (`gemini-2.5-flash`), `prompt`, `include_timestamps`.
- **Formatos**: mp3, wav, m4a, aac, flac, ogg, opus, mp4, mov, webm, avi, mkv.
- **Usos**: legendas, resumo de take, "o que essa pessoa fala".
- **Pedido**: "Transcreva `/Users/time/take-1.mp4` com timestamps."

#### `voice_command`
Transforma um comando de voz em edições reais no projeto.
- **Argumentos**: `audio_path`; opcionais `project_id`, `execute` (true), `context`, `model`, `speak_reply`, `voice_id`/`voice_name`.
- **Limites**: até 10 ações por comando; `remove_project` nunca é executado automaticamente.
- **Preview**: `execute: false` mostra o plano sem aplicar.
- **Requer**: `GEMINI_API_KEY`; `ELEVENLABS_API_KEY` só para `speak_reply`.
- **Pedido**: "Processe o comando de voz `/Users/time/cmd.m4a` no projeto `abc123`."

Fluxo por voz:

```
gravar instrução  →  voice_command  →  plano validado  →  edições  →  confirmação (opcional falada)
```

---

### 5.9 Renderização

#### `render_project`
Renderiza o draft em arquivo de vídeo usando o renderer Remotion embutido.
- **Argumentos**: `project_id`; opcionais `output_path`, `codec` (`h264`, `h265`, `vp8`, `vp9`, `prores`), `concurrency`.
- **Saída padrão**: `<projeto>/renders/render-<timestamp>.mp4`.
- **Renderiza fielmente**: clipes de vídeo/imagem/áudio, trim, posição, escala, flip, rotação, opacidade, volume, loop, textos, transforms, keyframes, blend modes e animações de texto curadas.
- **Não renderiza**: transições, efeitos, stickers, filtros e máscaras (são reportados como camadas ignoradas).
- **Requer**: Node.js 18+ e `npm install` dentro de `renderer/`.
- **Pedido**: "Renderize o projeto `abc123` em MP4."

---

## 6. Receitas prontas

### 6.1 Reel vertical do zero

1. "Crie um projeto 1080x1920 a 30fps chamado `Reel Promo`."
2. "Adicione o vídeo `/caminho/gancho.mp4` de 0 a 5s."
3. "Adicione o vídeo `/caminho/produto.mp4` aos 5s por 8s."
4. "Adicione o texto `50% OFF` de 1000 a 4000ms, branco, na parte de baixo, com a identidade da marca."
5. "Aplique fade-in no texto."
6. "Renderize o projeto em MP4."

### 6.2 B-roll gerado por IA

1. "Gere um vídeo 9:16 de 5s no Runway: `close-up de café sendo servido, luz natural`."
2. "Adicione esse clipe aos 3s do projeto `abc123`."
3. Se quiser economizar: use `seedance-2.5-text-to-video-480p`.

### 6.3 Narração + legendas

1. "Transcreva `/caminho/take.mp4` com timestamps."
2. "Gere uma narração com a voz Rachel dizendo `<texto>` e adicione no início."
3. "Crie um texto para cada trecho da transcrição, de 0 a 3s, 3 a 6s, etc."

### 6.4 Identidade de marca

1. "Defina a marca: primária `#FFB13D`, texto `#FFFFFF`, título Poppins 16."
2. "Adicione o texto `Nova coleção` usando a identidade da marca."
3. "Mostre as pendências e promova as cores aprovadas para a marca."

### 6.5 Comando por voz

1. Grave no celular: "Coloca um título dizendo Black Friday no começo e tira o áudio da música."
2. "Processe o comando de voz `/caminho/recording.m4a` no projeto `abc123`."
3. Peça `execute: false` primeiro se quiser revisar o plano.

---

## 7. Limitações conhecidas

- O render é uma **aproximação** feita com Remotion, não o motor do CapCut. Fontes podem cair para alternativas.
- Transições, efeitos, stickers, filtros e máscaras **não são renderizados**; são reportados como ignorados.
- Apenas drafts **locais** são acessíveis (projetos na nuvem não).
- IDs de efeitos/templates variam por versão do CapCut (testado na v8.3.0).
- `generate_video` (Runway MCP) e `generate_speech` dependem de chaves e créditos/cota dos provedores.
- `voice_command` executa no máximo 10 ações e nunca remove projeto automaticamente.

---

## 8. Solução de problemas

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `402` no `generate_video` | Créditos Runway zerados | Adicionar créditos em https://dev.runwayml.com |
| `401/403` no `generate_video` | `RUNWAYML_API_SECRET` inválida | Gerar nova chave, salvar em `runway-mcp/.env` e reiniciar o MCP |
| "API key not configured" | Chave ausente | Configurar no `.env` e reiniciar |
| "Project not found" | `project_id` errado | Rodar `list_projects` |
| "Clip not found" / "segment not found" | `clip_id` errado | Rodar `get_timeline` |
| "File not found" no `add_clip` | Caminho relativo ou arquivo inexistente | Usar caminho absoluto |
| Render falha por `node_modules` | Dependências do renderer ausentes | `cd renderer && npm install` |
| Render falha por `node` | Node.js < 18 | Instalar Node 18+ |
| Timeout na geração | Modelo demorou mais que o limite | Aumentar `timeout_ms` |
| Fonte diferente no render | Fonte não instalada | Usar fonte padrão do sistema ou instalar a fonte |

---

## 9. Boas práticas e segurança

- **Nunca** commite o `.env` nem cole chaves em conversas. O `.env` já está no `.gitignore`.
- Confirme antes de `remove_project` e antes de gerar vídeos caros (Seedance 1080p/4K).
- Use `seedance-2.5-text-to-video-480p` ou `runway-text-to-video` para rascunhos baratos.
- Prefira `get_timeline` antes de qualquer alteração em clipe existente.
- Para revisar comandos de voz, use `execute: false`.
- Mantenha a marca centralizada com `set_brand` para o time inteiro usar a mesma paleta.

---

## 10. Checklist rápido

- [ ] Projeto identificado (`project_id`)?
- [ ] Tempos informados em ms?
- [ ] `clip_id` obtido via `get_timeline` (quando for alterar)?
- [ ] Caminho absoluto do arquivo (quando for adicionar mídia)?
- [ ] Chaves e saldo disponíveis (para geração/TTS/transcrição)?
- [ ] Modelo e resolução escolhidos pensando no custo?
- [ ] `render_project` configurado (`npm install` no renderer)?
- [ ] Projeto removido só depois de confirmar?
