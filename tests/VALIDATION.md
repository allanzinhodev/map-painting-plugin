# Validação das funcionalidades

Ambiente: Aseprite Steam 1.3.18.3 x64, cliente 8.60 personalizado e fontes locais do NexaMap compilados em Release x64 com Visual Studio.

| Funcionalidade | Verificação executada | Resultado |
| --- | --- | --- |
| Leitura DAT/SPR/OTFI | Arquivos reais: 4.990 itens, 254 outfits, 25 efeitos, 15 projéteis; todas as 10.413 sprites decodificadas | PASS |
| Exportação dos recursos | Sem edição: DAT/SPR idênticos byte a byte; edições com alpha parcial; atributos e durações preservados; IDs compartilhados isolados | PASS |
| Renderização e spritesheets | Orientação de itens de vários tiles, camadas sobrepostas, alpha parcial e apagamento de pixels | PASS |
| Navegador de itens | Janela nativa construída, miniaturas pintadas e timer executado no Aseprite com interface; perfil de teste isolado | PASS |
| Vínculos por `#ID` | Eventos reais de edição, propagação entre documentos, edições simultâneas, cel recortada e preservação de outros IDs | PASS |
| Persistência `.aseprite` | Reabertura recupera UUIDs, metadados e pixels editados após novo carregamento dos recursos | PASS |
| Cenas editáveis | IDs, empilhamento, flags, casa, zonas, andares, movimento de 32 pixels e dados OTBM preservados | PASS |
| Atributos nativos | Atributos tipados, pilhas, fluidos, containers aninhados, destino de teleporte, porta e depot; serialização de ida e volta idêntica | PASS |
| Preparação da colagem | Código de produção preserva ordem dos objetos, combina flags/zonas, substitui tiles com chão e mantém cópias independentes; nenhuma entrada ou vizinho alterado antes da ação nativa | PASS |
| Publicação com backup | Aplicação em cópias de teste, backup exato e recusa de mudanças externas; recursos originais não editados pelos testes | PASS |
| Fluxo completo entre programas | NexaMap gera pacote → Aseprite importa, edita e move → NexaMap restaura e verifica bytes, posições e ordem dos itens | PASS |
| Instalação | Comando `TibiaSync` registrado pelo plugin instalado; hashes dos arquivos instalados correspondem aos fontes e ao executável testados | PASS |

Execute `scripts/Test.ps1` após construir e instalar para repetir os testes automáticos. `tests/*-result.txt` e `tests/native-result.json` guardam os resultados. O teste de interface está em `tests/ui-smoke.lua`; ele precisa de uma sessão gráfica e das permissões normais de arquivos do Aseprite.

Os testes do mapa usam seleções sintéticas com tipos do banco real de itens. Não alteram mapas de produção. A cena representa itens; criaturas e spawns são transportados como metadados. Novas ocorrências podem ser criadas duplicando camadas importadas; desenho livre e mudança de Server ID não são inferidos de pixels.
