# Integração Supabase — CRM Mori Ortodontia

## Estado atual

- Projeto Supabase: `rynlzkdqxbzwcznufnpn`
- URL pública: `https://rynlzkdqxbzwcznufnpn.supabase.co`
- Clínica Mori já criada no banco.
- 79 pacientes e 52 indicações já migrados.
- RLS habilitado nas tabelas públicas.
- O `index.html` atual ainda usa estado local e contém dados seed/demo.

## Regra de segurança

O navegador pode receber somente a Publishable Key do Supabase. Nunca colocar `service_role`, senha de banco ou qualquer segredo administrativo no HTML/JS.

A Publishable Key deve ser configurada no deploy/ambiente e disponibilizada ao cliente como `window.MORI_SUPABASE_PUBLISHABLE_KEY`. Não registrar a chave neste arquivo.

## Objetivo desta branch

Transformar o CRM atual em cliente do Supabase sem alterar a interface homologada da V2.1.

A ordem obrigatória é:

1. Adicionar Supabase JS v2.
2. Inicializar o cliente usando URL pública + Publishable Key.
3. Criar tela de login antes do shell do CRM.
4. Carregar sessão com `supabase.auth.getSession()`.
5. Depois do login, localizar o `profile` ativo do usuário e sua `clinica_id`.
6. Carregar dados da clínica via Supabase.
7. Mapear dados SQL para o formato que as funções atuais do CRM esperam em `DB`.
8. Só então renderizar o CRM.
9. Substituir gravações locais por operações Supabase progressivamente.
10. Remover seeds/demo somente depois de leitura e CRUD estarem validados.

## Carregamento inicial

Carregar, no mínimo:

- `clinicas`
- `profiles`
- `procedimentos`
- `origens_lead`
- `motivos_perda`
- `etapas_funil`
- `pacientes_com_status`
- `paciente_procedimentos`
- `indicacoes`
- `followups`
- `acoes_comerciais`

Todas as consultas devem depender da sessão autenticada e das políticas RLS. Não usar filtros de `clinica_id` como substituto de RLS.

## Compatibilidade com a V2.1

O frontend atual espera objetos de paciente com nomes camelCase. Criar uma camada de mapeamento, por exemplo:

- `telefone_original` -> `telefone`
- `procedimento_original` -> `procedimentoOriginal`
- `data_contato` -> `dataContato`
- `marcou_consulta` -> `marcouConsulta`
- `data_consulta` -> `dataConsulta`
- `fez_radiografia` -> `fezRadiografia`
- `plano_tratamento` -> `planoTratamento`
- `data_envio_plano` -> `dataEnvioPlano`
- `valor_orcamento` -> `valorOrcamento`
- `fechou_tratamento` -> `fechouTratamento`
- `valor_fechado` -> `valorFechado`
- `data_fechamento` -> `dataFechamento`
- `data_perda` -> `dataPerda`
- `observacoes` -> `observacoes`

`origem`, `responsavel`, `motivoPerda` e `procedimentos` devem ser resolvidos a partir das tabelas relacionadas.

O `id` usado pela interface deve passar a ser o UUID real do paciente. `legacy_id` é apenas referência histórica.

## CRUD de pacientes

### Criar

Ao salvar um novo paciente:

1. INSERT em `pacientes`.
2. Usar o UUID retornado.
3. INSERT dos procedimentos em `paciente_procedimentos`.
4. Recarregar o paciente ou atualizar `DB` com o retorno real do banco.

### Editar

1. UPDATE em `pacientes` pelo UUID.
2. Sincronizar `paciente_procedimentos`.
3. Atualizar a interface somente após sucesso do banco.

### Excluir

Não implementar exclusão definitiva nesta primeira etapa. Manter o comportamento atual bloqueado até definirmos arquivamento/auditoria.

## Indicações

A tela deve ler `indicacoes` do banco e preservar os três tipos:

- `paciente`
- `profissional`
- `outro`

Nunca inventar indicador quando o registro histórico estiver vazio.

## Ações comerciais

`acoes_comerciais` representa ocorrências concluídas, não tarefas pendentes permanentes.

Tipos:

- `pos_venda`
- `followup_plano`
- `resgate`

Ao clicar em concluir uma ação, gravar uma ocorrência no Supabase com `data_elegivel`. A constraint do banco evita duplicar a mesma ocorrência.

## localStorage

Após integração completa, localStorage não será fonte de verdade para dados clínicos.

Pode permanecer apenas para preferências locais sem informação clínica, como tema e eventualmente filtros de interface.

Não persistir pacientes, indicações, valores, telefones, e-mails, observações ou histórico comercial em localStorage.

## Dados demo

Remover do fluxo de produção:

- `DADOS_DEMO_V2`
- pacientes demo
- conversas falsas de WhatsApp
- mensagens falsas
- restauração automática de seed de pacientes

O módulo WhatsApp pode continuar visualmente indisponível/placeholder até a integração oficial da WhatsApp Business Platform.

## Critérios de aceite antes de merge na main

1. Usuário não autenticado não vê dados.
2. Login válido abre o CRM.
3. Usuário de uma clínica não consegue consultar outra clínica.
4. Lista mostra 79 pacientes da base atual.
5. Indicações mostram 52 registros.
6. Dashboard usa dados do Supabase.
7. Criar paciente persiste após recarregar a página.
8. Editar paciente persiste após recarregar a página.
9. Concluir follow-up/resgate persiste no banco.
10. Nenhum dado clínico novo depende de localStorage.
11. Nenhuma `service_role` ou segredo administrativo existe no frontend.
12. A V2.1 mantém layout, filtros, Kanban e regras de status.

## Não fazer nesta etapa

- WhatsApp Cloud API real.
- IA do Assistente de Vendas.
- automações de mensagem.
- financeiro completo.
- permissões financeiras avançadas.

Esses módulos entram depois que Auth + Supabase CRUD estiverem estáveis.