# CRM Mori Ortodontia + Landing Page Institucional (Clínica que Converte)

Este repositório reúne dois entregáveis distintos da **Clínica que Converte**:

1. O CRM comercial adaptado para a **Mori Ortodontia** (Belo Horizonte, MG), com os dados reais da clínica migrados da planilha própria que ela já usava.
2. A landing page institucional da própria **Clínica que Converte**, que apresenta a empresa como um todo e as três frentes de atuação (sistemas, mentoria para donos, mentoria para secretárias).

## Como abrir

- `index.html`: CRM da Mori Ortodontia. Protótipo local, single-file (HTML + CSS + JS), sem backend, todo o estado fica salvo no `localStorage` do navegador (chave `cqc_crm_state_v1`). Contém dados reais de pacientes, não deve ser publicado ou linkado publicamente sem antes remover/anonimizar esses dados.
- `landing-institucional.html`: landing page institucional da Clínica que Converte. Também single-file (HTML + CSS + JS), sem dados sensíveis, pode ser publicada normalmente. Abra direto no navegador ou publique como página estática.

## Estrutura do projeto

- `index.html`: o CRM da Mori Ortodontia (Assistente de Vendas, Pacientes, Kanban, Indicações, Dashboard, Agenda, Configurações).
- `landing-institucional.html`: landing page principal da Clínica que Converte (hero, o problema, abordagem de diagnóstico, as três frentes em bento grid, como funciona o processo, sobre, prova de entrega, diferencial de marca, FAQ, CTA final).
- `CLAUDE.md`: instruções-base do método Clínica que Converte, para continuidade de projeto no Claude Code.
- `briefing-preenchido.md`: briefing da Mori Ortodontia, específico do projeto de CRM.
- `Contexto/`: documentos de fundação do método (história, briefing modelo, especificação técnica do CRM-base, marketing/branding) e a planilha original da clínica (`CRM_Mori_Ortodontia.xlsx`), fonte dos 52 pacientes e 37 indicações reais migrados para o CRM.

## Status

- CRM (`index.html`): funcional para uso interno/demonstração. Ainda não está pronto para uso diário com pacientes reais, falta banco de dados online e login real (ver checklist dentro do próprio CRM, em Configurações, e `Contexto/03-crm-base-clinica-que-converte.md`).
- Landing institucional (`landing-institucional.html`): primeira versão completa, pronta para revisão. A seção "Sobre" usa um retrato provisório (monograma), precisa de foto profissional real antes de publicar.
