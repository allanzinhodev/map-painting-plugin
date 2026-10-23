# Open Tibia Painting

Extensão para o Aseprite 1.3.18.3 da Steam e ponte nativa para o NexaMap local. O perfil inicial é o cliente 8.60 personalizado de `backlands-workflow/client/data/things/860`: sprites 32×32, RGBA, IDs estendidos, duração de animações e grupos de frames conforme `Tibia.otfi`.

## Usar no Aseprite

Abra **File > Scripts > Open Tibia Painting > Navegar itens…**. A janela compacta mostra 18 miniaturas por página, busca por ID e prévia animada. Cada item abre em um documento com sua spritesheet: colunas são frames; linhas são grupos e padrões; camadas correspondem às camadas do DAT. As slices identificam as linhas. Use a grade de 32 pixels.

Ao editar uma spritesheet ou uma ocorrência vinculada, o plugin propaga os pixels às outras ocorrências daquele Client ID nos documentos abertos, respeitando a variante. Também é possível nomear uma camada RGB `#1234` para vinculá-la ao item. Não use esse prefixo em camadas que devem permanecer independentes. **Sincronizar** força a atualização; a caixa de propagação automática permite pausá-la.

Salve em `.aseprite` para preservar camadas, vínculos e metadados. Edite na primeira frame do documento; as animações Tibia aparecem nas colunas da spritesheet. Arquivos fechados conservam sua última edição salva e são reconciliados ao serem reabertos com o projeto carregado. Documentos PNG não conservam os vínculos.

**Exportar DAT/SPR…** grava uma cópia dos recursos em outra pasta. **Aplicar ao cliente** publica as edições nos arquivos carregados, com backup em `.tibia-workbench-backups` na pasta dos recursos. Se outro programa mudou os recursos desde o carregamento, a aplicação é interrompida para evitar perder essas mudanças. No NexaMap, use **Edit > Aseprite > Reload client sprites** após aplicar.

## Trocar cenas editáveis

1. No NexaMap integrado, selecione os itens e use `Ctrl+C` ou **Edit > Aseprite > Copy scene to Aseprite**.
2. No Aseprite, clique em **Colar cena NexaMap**. Cada ocorrência fica em uma camada `#ID`, organizada por andar.
3. Edite os pixels e mova itens em múltiplos de 32 pixels. Reordene as camadas para mudar o empilhamento. Excluir uma camada ou sua cel remove a ocorrência da cena devolvida. Ocultar uma camada só afeta a visualização.
4. Use **Copiar cena para NexaMap**, depois **Edit > Aseprite > Paste scene from Aseprite** no editor. Clique no mapa para colar; `Ctrl+Z` desfaz a colagem.
5. Para refletir as mudanças de pixels no mapa, use também **Aplicar ao cliente** e **Reload client sprites**. O pacote da cena transporta os itens e a composição; DAT/SPR transportam os pixels.

**Exportar cena PNG…** gera uma imagem da composição. Criaturas e spawns selecionados são preservados como metadados; esta versão desenha os itens. Desenho livre em camadas sem vínculo não cria um item de mapa. A troca de tipo/ID de itens importados deve ser feita no NexaMap, pois Server IDs diferentes podem compartilhar um Client ID. É preciso usar o mesmo cliente e banco `items.otb` nos dois lados.

Os atributos completos dos itens, incluindo containers e destinos de teleporte, viajam como nós OTBM e são verificados byte a byte na restauração. O retorno usa a colagem nativa com histórico e não aplica bordas automáticas à cena importada.

O diretório compartilhado configurado é `C:\Users\Allan\Aseprite_tibia\runtime`. No Aseprite, altere em **Recursos e integração…**. No NexaMap, a variável `TIBIA_ASEPRITE_EXCHANGE` pode substituir esse caminho. O transporte usa arquivos locais `nexa-scene.json` e `aseprite-scene.json`; o clipboard de texto/imagem do Windows não é necessário. Aseprite pode pedir sua permissão normal de acesso a arquivos na primeira utilização do script.

## Construir e instalar novamente

Em PowerShell, na pasta deste projeto:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build-Nexa.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Install-Nexa.ps1
```

A extensão é instalada em `%APPDATA%\Aseprite\extensions\tibia-workbench`. O pacote independente fica em `dist/tibia-workbench-0.1.0.aseprite-extension`. Reinicie o Aseprite após instalar ou atualizar.

A compilação usa o Visual Studio e as dependências vcpkg já instaladas no NexaMap; não baixa dependências. Os fontes do editor são compilados em `build/nexamap` com a sobreposição de `bridge/nexamap`. A instalação do editor substitui somente o executável, PDB e menu; o executável/menu anteriores ficam em `backups/nexamap-<data>`. Para restaurar, feche o NexaMap e copie esses arquivos de volta (`menubar.xml` pertence à pasta `data`). Os fontes do projeto externo permanecem disponíveis sem alteração. O patch e os fontes completos modificados estão em `bridge/`.

## Verificação

Os testes Lua são executados pelo próprio Aseprite em modo batch:

```powershell
& 'C:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe' --batch --script tests/codec.lua
& 'C:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe' --batch --script tests/integration.lua
& 'C:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe' --batch --script tests/publish.lua
```

O teste nativo do NexaMap gera `test-output/native-fixture-scene.json`; `tests/cross-language.lua` importa esse pacote no Aseprite, edita uma sprite, sincroniza uma spritesheet, move um item e devolve outro pacote. O validador nativo restaura esse retorno. Consulte os relatórios em `tests/*-result.txt` e `test-output/*.json`. Os testes modificam somente cópias dentro deste projeto.

Depois de construir e instalar, execute a bateria completa com `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test.ps1`. Ela também compara os bytes OTBM, posições e empilhamento depois do retorno ao código nativo. O teste de janela `tests/ui-smoke.lua` foi executado separadamente no Aseprite com interface gráfica e perfil de teste isolado.

## Licenças e referências

A extensão Lua usa MIT, com referência ao formato e às implementações do [ObjectBuilder](https://github.com/punkice3407/ObjectBuilder). Consulte `extension/LICENSE.txt`. A ponte conserva a licença GPL do [NexaMap/Remere's Map Editor](https://github.com/Mateuzkl/NexaMap-Editor), disponível em `bridge/LICENSE.rtf`; seu código correspondente acompanha o projeto. A API usada é a [API Lua do Aseprite](https://www.aseprite.org/api/plugin).
