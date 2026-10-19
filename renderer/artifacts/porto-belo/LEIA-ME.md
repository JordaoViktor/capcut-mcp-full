# Motion graphics — Porto Belo

Prévia independente criada em Remotion: 576 × 1024, 30 fps, 10 segundos, sem áudio.

Vídeo confirmado pelo usuário: `video-obra-legendado`. Versão final exportada em `~/Movies/video-obra/video-obra-motion-porto-belo.mp4`, com inserção de 00:01:00 até 00:01:10, entrada e saída em fade e manutenção do áudio original e das legendas. O arquivo original e o projeto CapCut foram preservados.

A seleção inicial traz MayBelly (Oporto) e Dallo (Palais Royal), sem ranking de tamanho. Os prédios desenhados são ilustrações genéricas, não representações desses empreendimentos. Nomes apresentados em tipografia própria, sem uso de logotipos oficiais.

Fontes oficiais consultadas em 09/10/2026:
- MayBelly / Oporto: https://maybelly.com.br/empreendimentos/oporto
- Dallo / empreendimentos entregues: https://www.dallo.com.br/empreendimentos/entregues/

Para renderizar novamente, na pasta renderer:

    node src/render-porto-belo.mjs

Composição: src/PortoBeloMotion.tsx. O parâmetro `transparent` permite adaptar o fundo para uma sobreposição; o MP4 entregue tem fundo sólido.

Para refazer a integração e exportar o vídeo completo:

    node src/finish-porto-belo.mjs

A exportação usa a prévia legendada existente como base. O áudio AAC é copiado sem recodificação. As legendas durante a inserção são renderizadas sobre os gráficos a partir do SRT original.
