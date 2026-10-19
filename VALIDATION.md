# Validação da entrega

Ambiente usado: Terraform 1.13.5, provider AWS 6.69.1 e Python 3.12.

| Verificação | Resultado |
| --- | --- |
| `terraform fmt -check -recursive` | Aprovada |
| `bash -n scripts/user-data.sh` | Aprovada |
| Compilação dos arquivos Python com `py_compile` | Aprovada |
| Três testes locais do verificador HTTP | Aprovados |
| `terraform validate` | Bloqueada pela restrição de sockets locais deste ambiente |
| 11 cenários de `terraform test` | Não concluídos pela mesma restrição do provider |
| Implantação e testes de integração na AWS | Não executados; exigem uma conta e recursos provisionados |
| Workflow no GitHub Actions | Incluído; ainda não executado no GitHub |

O provider foi obtido pelo mecanismo de instalação do Terraform com verificação da assinatura da HashiCorp. Ao iniciar o provider, o ambiente recusou a criação do socket Unix usado na comunicação com o Terraform (`socket: operation not permitted`). Isso impediu a validação de schema e a execução dos cenários simulados. Formatação e análise sintática não substituem essas verificações.

Depois de extrair o projeto em um ambiente que permita a execução do provider, rode `terraform init`, `terraform validate` e `terraform test`. O workflow incluído executa essas verificações sem credenciais da AWS. Os testes de integração só devem ser registrados como aprovados depois de uma execução contra os recursos reais.
