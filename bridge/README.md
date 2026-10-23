# Ponte NexaMap ↔ Aseprite

Os fontes em `nexamap/` são uma sobreposição dos fontes locais do NexaMap. O diretório `original/` registra exatamente os arquivos lidos antes da alteração; `original-sha256.json` permite verificar essa base. Não é preciso adicionar dependências nem arquivos ao projeto: o editor já usa nlohmann/json.

No NexaMap compilado com esta ponte, `Edit > Aseprite` oferece:

- **Copy scene to Aseprite**: copia os itens selecionados e publica a cena. O `Ctrl+C` comum também publica o mesmo pacote.
- **Paste scene from Aseprite**: restaura a cena no buffer nativo e mostra a prévia de colagem. Clique no mapa para colar; use `Ctrl+Z` para desfazer.
- **Reload client sprites**: recarrega os recursos do cliente usando o recarregamento já existente no editor.

O diretório de troca padrão é `C:/Users/Allan/Aseprite_tibia/runtime`. A variável de ambiente `TIBIA_ASEPRITE_EXCHANGE` pode substituí-lo. Configure o mesmo diretório na extensão do Aseprite. Os arquivos de troca são `nexa-scene.json` e `aseprite-scene.json`.

## Contrato da cena

O pacote JSON tem `format: "tibia-aseprite-scene"`, `version: 1`, `tileSize: 32`, `origin: {x,y,z}` e `mapVersion: {otbm,client}`. `tiles` contém coordenadas absolutas, `flags`, `houseId`, `zones` e `items` em ordem de baixo para cima. O chão aparece primeiro com `ground: true`.

Cada item contém `serverId`, `clientId`, `count`, `ground`, `visual` e `otbmHex`. O último campo é uma árvore nativa OTBM codificada em hexadecimal. Deve ser transportado sem alteração: guarda atributos tipados, conteúdo de containers e atributos especiais, incluindo destinos de teleporte. `visual` contém a variante visual que o NexaMap usou para o item. Criaturas e spawns selecionados seguem como metadados opcionais do tile; a edição visual da extensão trata os itens.

Os nós usam OTBM 4, cujo valor **nativo** do enum é `3`. Isso permite transportar atributos personalizados mesmo quando o mapa de origem usa uma versão antiga. `sourceMapVersion` registra a versão original. O ID de cliente do editor também é o valor nativo da versão, por exemplo `20` para 8.60.

A importação valida o formato, o cliente ativo e a correspondência Server ID → Client ID no `items.otb`. Cada item restaurado é serializado novamente e comparado byte a byte ao pacote. Qualquer erro conserva o buffer anterior e o mapa. A validação da árvore precede o leitor OTBM legado. Os limites são 64 MB por pacote, 100 mil itens e 64 níveis de containers. A colagem de cenas não executa a geração automática de bordas/paredes, para preservar a composição recebida.

Tiles recebidos com chão substituem o tile de destino e seus atributos. Tiles recebidos apenas com objetos acrescentam esses objetos ao destino, preservando sua ordem e combinando flags e zonas. A prévia e o desfazer são os do editor.

## Verificação nativa sem interface

Execute o editor com `--aseprite-bridge-selftest <items.otb> <relatorio.json>`. O processo lê o banco real de itens e verifica atributos personalizados, caracteres especiais, pilhas, líquidos, containers aninhados, teleporte, porta, depot, posições, andares, flags, casas, zonas, seleção e rejeição de dados corrompidos. A saída é o relatório JSON e `native-fixture-scene.json` no mesmo diretório.

Esse modo encerra antes de criar janelas ou carregar/salvar configurações. Como `wxApp::OnInit` retorna `false`, o código de saída do processo é `-1` mesmo quando os testes passam. Verifique `success: true` no relatório.

Para verificar um pacote exportado pelo Aseprite com o leitor nativo, execute `--aseprite-bridge-validate <items.otb> <pacote.json> <relatorio.json>`. O relatório inclui as coordenadas, andares, atributos dos tiles e itens reserializados após a restauração. Isso permite comparar também os bytes OTBM depois da ida e volta entre os aplicativos.

Os arquivos modificados conservam a licença GPL do NexaMap/Remere's Map Editor. A sobreposição e o patch devem acompanhar qualquer distribuição do executável modificado.
