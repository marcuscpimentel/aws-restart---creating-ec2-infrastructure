# EC2 com Terraform

Implementação de um servidor Apache no EC2, a partir dos conceitos do laboratório de introdução ao EC2 que estou estudando no AWS re/Start.

A proposta é acompanhar o ciclo da instância: criar com HTTP bloqueado, liberar a página, aumentar a capacidade e preparar a remoção. Cada estado está em um arquivo de variáveis. O Terraform cuida da infraestrutura; os testes verificam as configurações e o serviço publicado.

## O que o projeto cria

- Uma EC2 com Amazon Linux 2023 x86_64 e Apache instalado por user data.
- Um EBS raiz gp3 criptografado, removido junto com a instância.
- Um Security Group sem SSH. A porta 80 começa fechada.
- Uma VPC com sub-rede pública, Internet Gateway e rota para a internet, caso nenhuma sub-rede existente seja informada.

O tráfego HTTP chega pelo IPv4 público da EC2, passa pelo Security Group e é atendido pelo Apache. A saída para a internet fica liberada para instalar os pacotes. Não há Load Balancer, NAT Gateway, HTTPS ou Elastic IP neste projeto.

Mantive o monitoramento básico do EC2. O modo de créditos da T3 é `standard`, e o acesso aos metadados exige IMDSv2. Não há par de chaves nem perfil IAM na instância.

## Arquivos

| Caminho | Uso |
| --- | --- |
| `main.tf` | AMI, EC2 e Security Group |
| `network.tf` | Rede própria ou referência à sub-rede existente |
| `variables.tf` / `outputs.tf` | Entradas e saídas do projeto |
| `versions.tf` / `.terraform.lock.hcl` | Restrições de versão e versão selecionada do provider |
| `scripts/user-data.sh` | Instalação do Apache e criação da página |
| `scenarios/` | Estados do laboratório |
| `tests/lab.tftest.hcl` | Testes de configuração com provider simulado |
| `tests/integration.py` | Verificação da implantação real pela API e por HTTP |
| `.github/workflows/checks.yml` | Verificações automáticas no GitHub, sem credenciais AWS |

## Antes de executar

São necessários Terraform 1.7 ou superior, abaixo da versão 2, e credenciais AWS válidas no ambiente. Os testes de integração também usam Python 3.10+ e boto3. Os comandos abaixo consideram Bash; no Windows, podem ser executados pelo WSL.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
```

Revise `aws_region` no `terraform.tfvars`. O padrão é `us-east-1`. As credenciais devem vir de um perfil AWS, sessão de SSO ou variáveis de ambiente; não entram nos arquivos Terraform. O provider e o boto3 precisam usar a mesma conta e região.

Para usar a rede do ambiente do curso, preencha `existing_subnet_id` com uma sub-rede pública da Lab VPC e use a região do laboratório. Nesse modo, o Terraform só cria a EC2 e o Security Group. A rota para o Internet Gateway, o DNS e as regras de NACL da rede existente precisam estar configurados. O projeto não altera essa rede.

Contas de treinamento podem restringir o uso do Terraform, consultas ao SSM ou a criação de recursos. Informar a sub-rede existente não contorna essas permissões. Se necessário, `ami_id` permite informar uma AMI Amazon Linux 2023 x86_64 da mesma região sem consultar o parâmetro público.

## Estados do laboratório

| Arquivo | EC2 | EBS | HTTP | Proteção contra término |
| --- | --- | --- | --- | --- |
| `01-initial.tfvars` | t3.micro | 8 GiB | Bloqueado | Ativa |
| `02-http.tfvars` | t3.micro | 8 GiB | Liberado | Ativa |
| `03-resized.tfvars` | t3.small | 10 GiB | Liberado | Ativa |
| `04-cleanup.tfvars` | t3.small | 10 GiB | Liberado | Desativada |

Para criar a primeira etapa:

```bash
terraform plan -var-file=scenarios/01-initial.tfvars -out=initial.tfplan
terraform apply initial.tfplan
```

Os outros estados usam o mesmo diretório, workspace e state. Por exemplo, para liberar o HTTP e depois redimensionar:

```bash
terraform plan -var-file=scenarios/02-http.tfvars -out=http.tfplan
terraform apply http.tfplan

terraform plan -var-file=scenarios/03-resized.tfvars -out=resized.tfplan
terraform apply resized.tfplan
```

O resize deve atualizar a EC2 existente. A mudança de tipo envolve stop/start e interrompe o serviço. Revise o plano antes de aplicar: uma substituição da instância não é o resultado esperado para essa mudança. A proteção contra término não impede a parada.

O IPv4 público pode mudar no stop/start. Consulte `terraform output -raw web_url` novamente após o resize. O user data roda na primeira inicialização, e o Apache fica habilitado para voltar no boot seguinte.

O volume aumenta de 8 para 10 GiB, mas isso não comprova que a partição e o sistema de arquivos passaram a usar todo o espaço. Este projeto verifica o tamanho do EBS pela API; a expansão dentro do sistema operacional fica fora desse teste. Também não é possível reduzir o EBS existente de volta para 8 GiB. Para repetir a sequência desde o início, remova e recrie os recursos.

A AMI é descoberta pelo parâmetro público do Amazon Linux na criação. Mudanças posteriores no atributo `ami` são ignoradas para que uma nova versão publicada pela AWS não substitua a instância durante o exercício. Isso também vale para uma alteração posterior em `ami_id`. Uma troca de imagem exige uma substituição explícita, com a proteção desativada antes.

## Testes

### Configuração, sem conta AWS

```bash
terraform fmt -check -recursive
terraform validate
terraform test
```

O arquivo `tests/lab.tftest.hcl` usa `mock_provider "aws"` e execuções com `command = plan`. Os testes não chamam as APIs da AWS nem criam recursos. O `init` ainda precisa baixar o provider.

São 11 cenários: estado inicial, HTTP público, HTTP restrito a um IP, resize, preparação da remoção, reutilização de sub-rede, AMI explícita e quatro entradas inválidas. Entre as verificações estão a ausência de regras de entrada na primeira etapa, a liberação exclusiva da porta 80, a proteção contra término, a criptografia do EBS e a exigência de IMDSv2.

Esses testes verificam o plano e as regras do projeto. Não comprovam que a AWS aceitou a implantação ou que o Apache iniciou.

Também há três testes locais para o verificador HTTP: uma resposta correta, uma página diferente com status 200 e uma resposta 500 que contém o marcador esperado. Depois de instalar `requirements-test.txt`, execute:

```bash
python -m unittest discover -s tests -p 'test_http_probe.py' -v
```

O workflow `Checks` executa a validação, os cenários simulados, a checagem de sintaxe do bootstrap e os testes locais de HTTP em pushes e pull requests. Ele não faz `apply` na AWS. Isso considera que os arquivos deste projeto estão na raiz do repositório.

### Integração, com os recursos na AWS

Depois de aplicar uma etapa, gere as saídas e execute o teste correspondente:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-test.txt

terraform output -json > terraform-outputs.json
python tests/integration.py --stage initial
```

Nas etapas seguintes, atualize o arquivo de saídas antes de testar:

```bash
terraform output -json > terraform-outputs.json
python tests/integration.py --stage http

# Após aplicar 03-resized.tfvars:
terraform output -json > terraform-outputs.json
python tests/integration.py --stage resized
```

O argumento `--stage` define os resultados esperados independentemente das saídas do Terraform. O arquivo de saídas fornece os identificadores e a região; os valores reais são consultados na AWS.

| Verificação | O que é conferido |
| --- | --- |
| EC2 | Status checks, estado running, tipo, sub-rede, VPC, IP e associação exclusiva ao Security Group do projeto |
| EBS | Tamanho esperado, gp3, criptografia, vínculo com a EC2 e exclusão no término |
| Rede | Nenhuma entrada na etapa inicial; nas demais, somente TCP 80 para o CIDR informado |
| Proteção | Valor real de `DisableApiTermination` |
| Metadados e monitoramento | IMDSv2 obrigatório e monitoramento detalhado desativado |
| Serviço | Conexão bloqueada na etapa inicial; depois, HTTP 200 com o marcador da página do projeto |
| CloudWatch, opcional | Presença de pontos de CPUUtilization nos últimos 30 minutos |

O teste de proteção consulta o atributo; ele não tenta terminar a instância. A falha de conexão na primeira etapa é uma evidência complementar à leitura das regras do Security Group, não um diagnóstico isolado de firewall.

O teste espera os status checks por até 600 segundos e, nas etapas com HTTP, espera a página por até mais 600 segundos. É possível ajustar esse prazo com `--timeout`. Um erro retorna código de saída diferente de zero. Os testes não criam, alteram ou removem recursos.

Para incluir a consulta de métricas:

```bash
python tests/integration.py --stage resized --check-metrics
```

Métricas básicas têm intervalo de cinco minutos e podem demorar a aparecer. Sem essa opção, o teste de pontos de CPU aparece como ignorado. Se ela for usada e ainda não houver pontos, o teste falha e informa que é preciso aguardar. Ler métricas pela API pode ter custo.

Se mudar `http_cidr`, execute o teste a partir de um endereço permitido e passe o mesmo CIDR em `--http-cidr`. Os testes reais precisam de `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVolumes` e `ec2:DescribeInstanceAttribute`. A consulta opcional usa `cloudwatch:GetMetricStatistics`. Essas são permissões dos testes, não a lista de permissões para provisionar a infraestrutura.

### Verificação desta entrega

A validação local e os cenários simulados são registrados em `VALIDATION.md`. Os testes de integração precisam ser executados após uma implantação em conta AWS. Nenhum resultado de implantação real é presumido aqui.

## Remoção

Se passou pela sequência até o resize, aplique o quarto estado e então remova:

```bash
terraform plan -var-file=scenarios/04-cleanup.tfvars -out=cleanup.tfplan
terraform apply cleanup.tfplan
terraform output -json > terraform-outputs.json
python tests/integration.py --stage cleanup-ready
terraform destroy -var-file=scenarios/04-cleanup.tfvars
```

Se parou antes do resize, não use o quarto estado, pois ele também muda o tipo e o disco. Desative a proteção mantendo o estado em que parou. Exemplo para a primeira etapa:

```bash
terraform apply -var-file=scenarios/01-initial.tfvars -var='termination_protection=false'
terraform destroy -var-file=scenarios/01-initial.tfvars -var='termination_protection=false'
```

Para a segunda etapa, use `02-http.tfvars` nos dois comandos. A desativação precisa ser aplicada antes do `destroy`; passar a variável apenas no comando de remoção não atualiza o atributo da EC2. A configuração não usa `force_destroy`.

## Limites e custos

Este é um servidor de estudo em uma única zona de disponibilidade. O HTTP é sem criptografia, e a origem padrão é `0.0.0.0/0`, como no exercício. A configuração não é uma arquitetura de produção.

EC2, EBS, IPv4 público e transferência de dados podem gerar cobrança. Não há garantia de gratuidade por usar `t3.micro`. Parar a instância não remove os custos de armazenamento. Ao terminar, confira se o `destroy` foi concluído.

O state fica local e precisa ser preservado até a remoção. Não publique state, credenciais, planos ou o arquivo de saídas. O `.gitignore` exclui esses arquivos; os cenários públicos e o lock do provider devem ser versionados.

## Referências

- [Testes do Terraform](https://developer.hashicorp.com/terraform/language/tests)
- [Provider simulado nos testes](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [Recurso aws_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance)
- [Proteção contra término no EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_ChangingDisableAPITermination.html)
- [Expansão do sistema de arquivos após aumentar o EBS](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)
