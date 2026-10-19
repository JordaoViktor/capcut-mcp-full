# Porto Belo — animação com contexto de design THC

Vídeo final: ~/Movies/video-obra/video-obra-motion-porto-belo-design.mp4

Inserção em 01:00–01:10. Vídeo completo: 72,1 s, 576 × 1024, 30 fps, H.264/AAC.

Contexto aplicado: ~/.config/capcut-mcp/brand.json, mesclado com os overrides de 0344C802-2BB0-4763-9DF0-B6B4ECDE15F5. A configuração efetivamente usada está em brand-aplicada.json. Seu status é estimated: paleta provisória e fontes substitutas, conforme o contexto fornecido.

- Vinho, grafite, champanhe, marfim e acentos dourados.
- Cormorant Garamond e Montserrat, fontes locais com licenças OFL em renderer/public/porto-belo-brand.
- Logo THC oficial copiado do arquivo local de marca, sem redesenho.
- Desenho arquitetônico genérico; não representa os empreendimentos citados.
- Traçado progressivo, movimento lento e fades de 12 quadros.
- Mesmo conteúdo: MayBelly / Oporto e Dallo / Palais Royal, sem ranking.

O áudio AAC foi copiado sem recodificação e seu SHA-256 foi comparado com o vídeo-base: idêntico. As legendas no trecho da animação vêm do SRT original, agora com a tipografia do contexto. Fora do trecho, foi usada a mesma prévia legendada da versão anterior. O projeto CapCut e a exportação anterior não foram alterados.

Validação: TypeScript sem erros; duração, resolução e áudio conferidos; quadros da exportação inspecionados em 63 s, 68 s e na transição de saída.

Para refazer, dentro de renderer:

    node src/finish-porto-belo-editorial.mjs
