#!/bin/bash
# Self-check for the plan pass script of terraform-module-pr-review, run under bash and
# under zsh, with terraform and aws stubbed. No network, no AWS account.
# Run: tests/plan-pass-test.sh
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
PP="$SRC/.agents/skills/terraform-module-pr-review/references/plan-pass.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/plan-pass-test.XXXXXX")" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL no temporary directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name, command status (0 = holds)
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
has() { printf '%s\n' "$1" | grep -xF -- "$2" > /dev/null; echo $?; }
lacks() { printf '%s\n' "$1" | grep -F -- "$2" > /dev/null && echo 1 || echo 0; }

# With grep -q, a match on line 1 of large output can make printf die of SIGPIPE, and
# pipefail then reads the leak as absent. lacks must read all its input to catch it.
big="leaked-canary-value
$(head -c 600000 /dev/zero | tr '\0' x | fold -w 100)"
check "lacks catches a leak on the first line of large output" "$([ "$(lacks "$big" leaked-canary-value)" = 1 ]; echo $?)"
unset big

# Stubs. terraform keys its behaviour on the example directory's name, and logs each call.
mkdir -p "$TMP/bin" "$TMP/noaws"
# What the stubbed terraform show -json prints: resource changes, a deferred data source read
# among them, and the data sources the plan read, in prior_state and planned_values: one in a
# module instance, one with a map attribute, one sensitive, one orphaned (in no data block of
# the configuration), a managed entry of prior_state, and a malformed data address.
jq -n -c '{
  resource_changes: [
    {address: "module.s3.aws_s3_bucket.this[\"k1\"]", change: {
      after: {bucket: "b", tags: null, versioning: [{enabled: true}], logging: [{target: "t"}]},
      after_unknown: {arn: true, id: false},
      after_sensitive: {bucket: true, tags: false, versioning: [{enabled: false}], logging: [{target: true}]}}},
    {address: "module.s3.aws_s3_bucket.this[\"k2\"]", change: {after: {region: "r"}, after_sensitive: {region: false}}},
    {address: "aws_kms_key.this", change: {after: {policy: "p"}}},
    {address: "weird name", change: {}},
    {address: "data.aws_iam_policy_document.deferred", mode: "data", change: {actions: ["read"],
      after: {json: null}, after_unknown: {json: true, statement: true}, after_sensitive: {}}}],
  prior_state: {values: {root_module: {
    resources: [
      {address: "data.aws_iam_policy_document.this", mode: "data", values: {json: "leaked-data-value",
        statement: [{actions: ["s3:GetObject"], condition: [{values: ["leaked-data-value"]}]}],
        override_policy_documents: null}, sensitive_values: {statement: [{condition: [{}]}]}},
      {address: "data.aws_x.map", mode: "data", values: {name: "n",
        filter: {leaked_map_key: "v", leaked_nested: {leaked_deep: "x"}}}, sensitive_values: {filter: {}}},
      {address: "data.aws_secretsmanager_secret_version.s", mode: "data",
        values: {arn: "a", secret_string: "leaked-data-value"}, sensitive_values: {secret_string: true}},
      {address: "data.aws_iam_policy_document.gone", mode: "data", values: {json: "j"}, sensitive_values: {}},
      {address: "data.aws_bad", mode: "data", values: {json: "j"}, sensitive_values: {}},
      {address: "aws_s3_bucket.stale", mode: "managed", values: {bucket: "b"}, sensitive_values: {}}],
    child_modules: [{address: "module.s3[\"k1\"]", resources: [
      {address: "module.s3[\"k1\"].data.aws_iam_policy_document.bucket[0]", mode: "data",
        values: {json: "j"}, sensitive_values: {}}]}]}}},
  planned_values: {root_module: {resources: [
    {address: "data.aws_iam_policy_document.deferred", mode: "data", values: {json: null}, sensitive_values: {}},
    {address: "data.aws_iam_policy_document.planned_only", mode: "data", values: {policy_id: "x"}, sensitive_values: {}}]}},
  configuration: {root_module: {
    resources: ([
      "data.aws_iam_policy_document.this", "data.aws_x.map", "data.aws_secretsmanager_secret_version.s",
      "data.aws_iam_policy_document.deferred", "data.aws_iam_policy_document.planned_only", "data.aws_bad"]
      | map({address: ., mode: "data"})) + [{address: "aws_s3_bucket.stale", mode: "managed"}],
    module_calls: {
      s3: {source: "terraform-aws-modules/s3-bucket/aws",
        module: {resources: [{address: "data.aws_iam_policy_document.bucket", mode: "data"}]}},
      local: {source: "../../"}}}}}' > "$TMP/show.json"
cat > "$TMP/bin/terraform" <<EOF
#!/bin/sh
echo "\${PWD##*/} \$1" >> "$TMP/tf.log"
case "\$1" in
show)
  # The saved plan is read with no credentials, from the file the plan wrote
  [ -z "\$AWS_ACCESS_KEY_ID" ] || echo "show with credentials" >> "$TMP/tf.log"
  for a; do f="\$a"; done; [ -f "\$f" ] || { echo "Error: no saved plan"; exit 1; }
  cat "$TMP/show.json" ;;
init)
  printf 'provider "registry.terraform.io/hashicorp/aws" {\n}\n' >> .terraform.lock.hcl
  if [ "\${PWD##*/}" = ok ]; then
    mkdir -p "\$TF_DATA_DIR/modules/s3"
    echo 'resource "aws_s3_bucket" "this" {}' > "\$TF_DATA_DIR/modules/s3/main.tf"
    printf '{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"s3","Source":"registry.terraform.io/terraform-aws-modules/s3-bucket/aws","Version":"4.1.0","Dir":"%s"}]}\n' \\
      "\$TF_DATA_DIR/modules/s3" > "\$TF_DATA_DIR/modules/modules.json"
  fi ;;
plan)
  [ -n "\$AWS_ACCESS_KEY_ID" ] || { echo "Error: no valid credential sources"; exit 1; }
  case "\${PWD##*/}" in
  ok) for a; do case "\$a" in -out=*) echo saved > "\${a#-out=}" ;; esac; done
    echo "Plan: 1 to add, 0 to change, 0 to destroy." ;;
  err) printf 'Error: bucket 123456789012 is not valid\n\n  on main.tf line 1\n'; exit 1 ;;
  leak) printf 'Error: invalid key s3cr3t-value-xyz\n\n'; exit 1 ;;
  split) printf 'Error: invalid key s3cr3t-val\nue-xyz\n\n'; exit 1 ;;
  esac ;;
esac
exit 0
EOF
# aws: assume-role answers with a session unless AWSSTS=fail, and logs its arguments; the
# dry-run write probe is refused unless the file probe says otherwise: the pass runs it under
# env -i, so a variable would not reach the stub. export-credentials is logged,
# so a test can show the profile's own credentials are never read.
cat > "$TMP/bin/aws" <<EOF
#!/bin/sh
case "\$1 \$2" in
--version*) echo "aws-cli/\${AWSVER:-2.15.0} Python/3.11" ;;
"configure export-credentials") echo "export-credentials" >> "$TMP/aws.log" ;;
"sts assume-role")
  printf '%s\n' "\$*" >> "$TMP/aws.log"
  case "\${AWSSTS:-ok}" in
  ok) ;;
  empty) echo '{}'; exit 0 ;;
  *) echo "An error occurred (AccessDenied) when calling the AssumeRole operation" >&2; exit 254 ;;
  esac
  echo '{"Credentials":{"AccessKeyId":"ASIAFIXTUREFIXTURE01","SecretAccessKey":"s3cr3t-value-xyz","SessionToken":"tok-fixture","Expiration":"2026-10-01T00:15:00Z"}}' ;;
"sts get-caller-identity")
  case "\$(cat "$TMP/ident" 2> /dev/null || echo ok)" in
  ok) echo '{"Account":"210987654321"}' ;;
  throttled) echo "An error occurred (Throttling) when calling the GetCallerIdentity operation: Rate exceeded for arn:aws:iam::210987654321:role/x" >&2; exit 254 ;;
  *) echo "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation" >&2; exit 254 ;;
  esac ;;
"ec2 create-vpc")
  case "\$(cat "$TMP/probe" 2> /dev/null || echo denied)" in
  denied) echo "An error occurred (UnauthorizedOperation) when calling the CreateVpc operation: You are not authorized to perform this operation." >&2 ;;
  allowed) echo "An error occurred (DryRunOperation) when calling the CreateVpc operation: Request would have succeeded, but DryRun flag is set." >&2 ;;
  *) echo "Could not connect to the endpoint URL" >&2 ;;
  esac
  exit 254 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/terraform" "$TMP/bin/aws"
ln -s "$TMP/bin/terraform" "$TMP/noaws/terraform"

ROLE='arn:aws:iam::210987654321:role/modulestf-review'

# The upstream repository: the base commit has examples/err only, the head adds the rest.
up="$TMP/upstream"
mkdir -p "$up/examples/err"
git -C "$up" init -q
echo 'resource "aws_s3_bucket" "this" {}' > "$up/main.tf"
echo 'module "b" { source = "../../" }' > "$up/examples/err/main.tf"
git -C "$up" add -A && git -C "$up" -c user.name=t -c user.email=t@example.invalid commit -qm base
BASE="$(git -C "$up" rev-parse HEAD)"
mkdir -p "$up/examples/ok" "$up/examples/leak" "$up/examples/split" "$up/examples/gate"
printf 'module "s3" {\n  source  = "terraform-aws-modules/s3-bucket/aws"\n  version = "4.1.0"\n}\n' > "$up/examples/ok/main.tf"
echo 'module "b" { source = "../../" }' > "$up/examples/leak/main.tf"
echo 'module "b" { source = "../../" }' > "$up/examples/split/main.tf"
echo 'resource "null_resource" "x" {}' > "$up/examples/gate/main.tf"
git -C "$up" add -A && git -C "$up" -c user.name=t -c user.email=t@example.invalid commit -qm head

# Per-file gate fixtures for the two modes, one file each. Runner mode must refuse every
# file but ok.tf; laptop mode must refuse ok.tf too.
mkdir -p "$TMP/rt"
w() { printf '%s\n' "$2" > "$TMP/rt/$1.tf"; }
w endpoints 'provider "aws" {
  region = "us-east-1"
  endpoints {
    s3 = "http://127.0.0.1"
  }
}'
w comment-brace 'provider "aws" { /* } */ endpoints { s3 = "http://127.0.0.1" }
}'
w hash-in-string 'provider "aws" {
  region = "#" endpoints { s3 = "http://127.0.0.1" }
}'
w both-tricks 'provider "aws" { /* } */ region = "#" endpoints { s3 = "http://127.0.0.1" }
}'
w renamed 'terraform {
  required_providers {
    foo = {
      source = "hashicorp/aws"
    }
  }
}
provider "foo" {
  endpoints {
    s3 = "http://127.0.0.1"
  }
}'
w dynamic-role 'provider "aws" {
  dynamic "assume_role" {
    for_each = [1]
    content {
      duration = "1h"
    }
  }
}'
w profile 'provider "aws" {
  profile = "other"
}'
w backend 'terraform {
  backend "s3" {}
}'
w cloud 'terraform {
  cloud {}
}'
w open-heredoc 'locals {
  x = <<EOT
abc
}'
w open-string 'locals {
  x = "abc
}'
w lookalike "$(printf 'locals {\n  caf\303\251 = 1\n}')"
w git-source 'module "a" {
  source = "git::https://example.invalid/x.git"
}'
w github-lookalike 'module "a" {
  source = "github.com.example.invalid/x"
}'
w docker 'terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}'
w unquoted-label 'provider aws {
  endpoints {
    s3 = "http://127.0.0.1"
  }
}'
# A keyword right against its label is valid HCL; a carriage return or form feed ends a
# heredoc for Terraform where the lexer would read on and hide what follows.
w adj-data 'data"aws_ssm_parameter""x"{
  name = "x"
}'
w adj-provider 'provider"aws"{
  endpoints {
    sts = "http://127.0.0.1"
  }
}'
w adj-module 'module"m"{
  source = "git::https://example.invalid/m"
}'
w cr-heredoc "locals {
  a = <<EOT
x
EOT"$'\r'"
}
provider \"aws\" {
  endpoints {
    sts = \"http://127.0.0.1\"
  }
}
locals {
  b = <<EOT
EOT
}"
w ff-heredoc "locals {
  a = <<EOT
x
EOT"$'\f'"
}
provider \"aws\" {
  endpoints {
    sts = \"http://127.0.0.1\"
  }
}
locals {
  b = <<EOT
EOT
}"
for u in nbsp:$'\xc2\xa0' ls:$'\xe2\x80\xa8'; do
  w "${u%%:*}-heredoc" "locals {
  a = <<EOT
x
EOT${u#*:}
}
provider \"aws\" {
  endpoints {
    sts = \"http://127.0.0.1\"
  }
}
locals {
  b = <<EOT
EOT
}"
done
w role-fixed 'provider "aws" {
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/example"
  }
}'
w role-variable 'provider "aws" {
  assume_role {
    role_arn = var.role_arn
  }
}'
w role-interpolated 'provider "aws" {
  assume_role {
    role_arn = "arn:aws:iam::${var.account}:role/example"
  }
}'
w role-extra 'provider "aws" {
  assume_role {
    role_arn    = "arn:aws:iam::123456789012:role/example"
    external_id = "x"
  }
}'
w role-and-endpoints 'provider "aws" {
  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/example"
  }
  endpoints {
    s3 = "http://127.0.0.1"
  }
}'
w role-twice 'provider "aws" {
  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/example"
  }
  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/other"
  }
}'
w build-in-docker 'module "lambda" {
  source          = "terraform-aws-modules/lambda/aws"
  runtime         = "python3.12"
  build_in_docker = true # the packaging calls Docker
}'
w build-in-docker-var 'module "lambda" {
  source          = "terraform-aws-modules/lambda/aws"
  build_in_docker = var.build_in_docker
}'
w build-in-docker-false 'module "lambda" {
  source          = "terraform-aws-modules/lambda/aws"
  build_in_docker = false
}'
w build-in-docker-nested 'module "lambda" {
  source = "terraform-aws-modules/lambda/aws"
  tags   = { build_in_docker = true }
  # build_in_docker = true
  description = "build_in_docker = true"
}'
w build-in-docker-and-backend 'terraform {
  backend "s3" {}
}
module "lambda" {
  source          = "terraform-aws-modules/lambda/aws"
  build_in_docker = true
}'
w docker-and-backend 'terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
  backend "s3" {}
}'
w ok "$(printf '%s\n' 'terraform {
  required_providers {
    aws        = { source = "hashicorp/aws" }
    null       = { source = "hashicorp/null" }
    external   = { source = "hashicorp/external" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}
provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  default_tags {
    tags = { Name = "x" }
  }
}
provider "kubernetes" {
  host  = "https://example.invalid"
  token = "t"
}
/* a block comment with a } brace */
resource "null_resource" "x" {
  provisioner "local-exec" {
    command = "echo ${path.module}"
  }
}
data "external" "x" {
  program = ["sh", "-c", "echo {}"]
}
locals {
  f = file("${path.module}/x.txt")
  s = "${join(",", ["a"])}"
  h = <<-EOT' "$(printf '    caf\303\251 "quoted" } #')" '  EOT
}
module "gh" {
  source = "github.com/terraform-aws-modules/terraform-aws-s3-bucket"
}
module "reg" {
  source = "terraform-aws-modules/s3-bucket/aws"
}
module "loc" {
  source = "../"
}
check "c" {
  assert {
    condition     = true
    error_message = "x"
  }
}')"

# Laptop relaxations of G3 (plan-pass.md, Data sources and provider flags). One tree per case
# under g3/<case>: ex is the example root, mod and mid are local modules.
g3w() { mkdir -p "$TMP/g3/$1/${2%/*}"; printf '%s\n' "$3" > "$TMP/g3/$1/$2"; }
POL='data "aws_iam_policy" "t" {
  count = var.on ? 1 : 0
  arn   = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}'
g3w pol-plain ex/main.tf "$POL"
g3w pol-partition ex/main.tf 'data "aws_partition" "current" {}
data "aws_iam_policy" "t" {
  arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaENIManagementAccess"
}'
pol() { g3w "pol-$1" ex/main.tf "data \"aws_iam_policy\" \"t\" {
$2
}"; }
pol account '  arn = "arn:aws:iam::123456789012:policy/x"'
pol anchor '  arn = "arn:aws:iam::123456789012:policy/xarn:aws:iam::aws:policy/X"'
pol var '  arn = var.arn'
pol interp '  arn = "arn:aws:iam::aws:policy/${var.x}"'
pol name '  name = "AWSXrayWriteOnlyAccess"'
pol provider '  provider = aws.other
  arn      = "arn:aws:iam::aws:policy/X"'
pol region '  region = "us-east-1"
  arn    = "arn:aws:iam::aws:policy/X"'
pol for-each '  for_each = toset(["a"])
  arn      = "arn:aws:iam::aws:policy/X"'
pol heredoc '  arn = <<EOT
arn:aws:iam::aws:policy/X
EOT'
pol multi-count '  count = (
    1
  )
  arn = "arn:aws:iam::aws:policy/X"'
pol dotdot '  arn = "arn:aws:iam::aws:policy/../X"'
pol dot '  arn = "arn:aws:iam::aws:policy/a/./X"'
pol brace '  arn = "arn:aws:iam::aws:policy/X}"'
pol comment '  # arn = "arn:aws:iam::aws:policy/X"
  arn = var.x'
pol long "  arn = \"arn:aws:iam::aws:policy/$(head -c 513 /dev/zero | tr '\0' a)\""
g3w free-arn ex/main.tf 'data "aws_arn" "a" {
  arn = var.queue_arn
}'
g3w free-doc ex/main.tf 'data "aws_cloudwatch_log_data_protection_policy_document" "d" {
  name = var.name
  statement {
    sid              = "Audit"
    data_identifiers = ["arn:aws:dataprotection::aws:data-identifier/EmailAddress"]
    operation {
      audit {
        findings_destination {}
      }
    }
  }
}'
g3w free-unlexed ex/main.tf 'data "aws_arn" "a" {
  arn = var.queue_arn
}
locals {
  x = <<EOT
  y
}'
g3w free-file ex/main.tf 'data "aws_arn" "a" {
  arn = file("arn.txt")
}'
# The event bus: a module directory read through the calls of the example root.
BUS='data "aws_cloudwatch_event_bus" "this" {
  count  = var.create ? 0 : 1
  name   = var.bus_name
  region = var.region
}'
VARS='variable "create" {
  default = false
}
variable "bus_name" {
  type    = string
  default = "default"
}
variable "region" {
  type    = string
  default = null
}'
bus() { # case, module call arguments, [variables]
  g3w "$1" mod/main.tf "$BUS"; g3w "$1" mod/variables.tf "${3:-$VARS}"
  g3w "$1" ex/main.tf "module \"m\" {
  source = \"../mod\"
$2
}"
}
g3w bus-root ex/main.tf 'data "aws_cloudwatch_event_bus" "this" {
  name   = "default"
  region = "eu-west-1"
}'
g3w bus-root-var ex/main.tf 'data "aws_cloudwatch_event_bus" "this" {
  name = var.bus_name
}'
bus bus-defaults ''
bus bus-null-name '  bus_name = null'
bus bus-null-region '  region = null'
NNV='variable "bus_name" {
  type     = string
  nullable = false
  default  = "%s"
}
variable "region" {
  default = null
}'
bus bus-nn-safe '  bus_name = null' "$(printf "$NNV" default)"
bus bus-nn-unsafe '  bus_name = null' "$(printf "$NNV" 'arn:aws:events:us-east-1:123456789012:event-bus/x')"
bus bus-nn-var '  bus_name = null' "$(printf "$NNV" default | sed 's/nullable = false/nullable = var.n/')"
bus bus-nonliteral '  bus_name = "${var.prefix}-bus"'
bus bus-arn '  bus_name = "arn:aws:events:us-east-1:123456789012:event-bus/x"'
bus bus-slash '  bus_name = "aws.partner/x"'
bus bus-region-fake '  region = "zz-fake-9"'
bus bus-region-host '  region = "eu-west-1.example.com"'
bus bus-two-calls ''
printf '%s\n' 'module "n" {
  source   = "../mod"
  bus_name = "a:b"
}' >> "$TMP/g3/bus-two-calls/ex/main.tf"
bus bus-unresolved ''
printf '%s\n' 'module "x" {
  source = "../nowhere"
}' >> "$TMP/g3/bus-unresolved/ex/main.tf"
g3w bus-zero mod/main.tf "$BUS"; g3w bus-zero mod/variables.tf "$VARS"
g3w bus-zero ex/main.tf '# source = "../mod"'
g3w bus-nested mod/main.tf "$BUS"; g3w bus-nested mod/variables.tf "$VARS"
g3w bus-nested mid/main.tf 'module "m" {
  source   = "../mod"
  bus_name = "default"
}'
g3w bus-nested ex/main.tf 'module "mid" {
  source = "../mid"
}'
bus bus-extra ''
printf '%s\n' "$BUS" | sed '$d' > "$TMP/g3/bus-extra/mod/main.tf"
printf '%s\n' '  depends_on = []' '}' >> "$TMP/g3/bus-extra/mod/main.tf"
bus bus-dup-name ''
printf '%s\n' "$BUS" | sed '$d' > "$TMP/g3/bus-dup-name/mod/main.tf"
printf '%s\n' '  name = "x"' '}' >> "$TMP/g3/bus-dup-name/mod/main.tf"
# Provider flags
PROV='provider "aws" {
  region = "eu-west-1"

  # Make it faster by skipping something
  skip_metadata_api_check     = true
  skip_credentials_validation = false
  // one more comment
  skip_requesting_account_id  = true
  skip_region_validation      = false
}'
g3w prov-skip ex/main.tf "$PROV"
g3w prov-skip-var ex/main.tf 'provider "aws" {
  skip_metadata_api_check = var.skip
}'
g3w prov-skip-unknown ex/main.tf 'provider "aws" {
  skip_everything = true
}'
g3w prov-region-true ex/main.tf 'provider "aws" {
  skip_region_validation = true
}'
g3w prov-endpoints ex/main.tf 'provider "aws" {
  skip_metadata_api_check = true
  endpoints {
    sts = "http://127.0.0.1"
  }
}'
# Data source regions, and skip_region_validation = true beside a literal region
g3w prov-region-true-literal ex/main.tf 'provider "aws" {
  region                 = "eu-west-1"
  skip_region_validation = true
}'
g3w prov-region-true-var ex/main.tf 'provider "aws" {
  region                 = var.region
  skip_region_validation = true
}'
g3w prov-region-true-s3 ex/main.tf 'provider "aws" {
  region                 = "s3.us-east-1"
  skip_region_validation = true
}'
g3w prov-region-true-comment ex/main.tf 'provider "aws" {
  region                 = "eu-west-1" # a trailing comment
  skip_region_validation = true
}'
reg() { g3w "reg-$1" ex/main.tf "data \"aws_availability_zones\" \"z\" {
$2
}"; }
reg root-literal '  region = "eu-west-1"'
reg root-null '  region = null'
reg root-absent '  state = "available"'
reg root-var '  region = var.region'
reg root-s3 '  region = "s3.us-east-1"'
reg root-local '  region = local.region'
reg root-interp '  region = "${var.r}"'
reg root-data '  region = data.aws_region.current.region'
reg root-twice '  region = "eu-west-1"
  region = "eu-west-2"'
REGM='data "aws_availability_zones" "z" {
  region = var.region
}'
REGV='variable "region" {
  type    = string
  default = null
}'
regm() { # case, module call arguments, [module data block]
  g3w "reg-$1" mod/main.tf "${3:-$REGM}"; g3w "reg-$1" mod/variables.tf "$REGV"
  g3w "reg-$1" ex/main.tf "module \"m\" {
  source = \"../mod\"
$2
}"
}
regm mod-default ''
regm mod-call-literal '  region = "eu-west-1"'
regm mod-literal '' 'data "aws_availability_zones" "z" {
  region = "us-east-1"
}'
regm mod-call-s3 '  region = "s3.us-east-1"'
regm mod-call-local '  region = local.region'
regm mod-local '' 'data "aws_availability_zones" "z" {
  region = local.region
}'
g3w reg-mod-zero mod/main.tf "$REGM"; g3w reg-mod-zero mod/variables.tf "$REGV"
g3w reg-mod-zero ex/main.tf '# source = "../mod"'
g3w reg-mod-nested mod/main.tf "$REGM"; g3w reg-mod-nested mod/variables.tf "$REGV"
g3w reg-mod-nested mid/main.tf 'module "m" {
  source = "../mod"
  region = "eu-west-1"
}'
g3w reg-mod-nested ex/main.tf 'module "mid" {
  source = "../mid"
}'
regm mod-ban ''
: > "$TMP/g3/reg-mod-ban/mod/x.tfvars"
g3w reg-unlexed ex/main.tf 'data "aws_availability_zones" "z" {}
locals {
  x = <<EOT
  y
}'
# Review cases: a module call or argument hidden from the call enumeration by a CR or FF
# after a heredoc end, or by a keyword against its label, and a mention outside a block.
XV="$VARS
variable \"x\" {
  default = null
}"
for c in crlf-arg crlf-call ff-arg nospace-call; do g3w "$c" mod/main.tf "$BUS"; g3w "$c" mod/variables.tf "$XV"; mkdir -p "$TMP/g3/$c/ex"; done
printf 'module "ok" {\n  source = "../mod"\n  x = <<EOT\ny\nEOT%b\n  bus_name = "arn:aws:events:us-east-1:123456789012:event-bus/x"\n  region   = "us-east-1.attacker.example"\n}\n\nlocals {\n  pad2 = <<EOT\nEOT\n}\n' '\r' > "$TMP/g3/crlf-arg/ex/main.tf"
printf 'module "ok" {\n  source = "../mod"\n  x = <<EOT\ny\nEOT%b\n  bus_name = "arn:aws:events:us-east-1:123456789012:event-bus/x"\n  region   = "us-east-1.attacker.example"\n}\n\nlocals {\n  pad2 = <<EOT\nEOT\n}\n' '\f' > "$TMP/g3/ff-arg/ex/main.tf"
printf 'module "ok" {\n  source = "../mod"\n}\n\nlocals {\n  pad = <<EOT\nx\nEOT%b\n}\n\nmodule "bad" {\n  source   = "../mod"\n  bus_name = "arn:aws:events:us-east-1:123456789012:event-bus/x"\n}\n\nlocals {\n  pad2 = <<EOT\nEOT\n}\n' '\r' > "$TMP/g3/crlf-call/ex/main.tf"
g3w nospace-call ex/main.tf 'module "ok" {
  source = "../mod"
}
module"bad"{
  source   = "../mod"
  bus_name = "arn:aws:events:us-east-1:123456789012:event-bus/x"
}'
g3w mention ex/main.tf "$POL
# data \"aws_iam_policy\" \"x\" { name = \"y\" }"
# Literal locals: resolved only from one single-line declaration in the same directory
AZL='data "aws_availability_zones" "z" {
  region = local.region
}'
g3w loc-root ex/main.tf "locals {
  region = \"eu-west-1\"
}
$AZL"
g3w loc-bus-root ex/main.tf 'locals {
  bus = "default"
}
data "aws_cloudwatch_event_bus" "this" {
  name = local.bus
}'
regm loc-call '  region = local.region'
printf '%s\n' 'locals {' '  region = "eu-west-1"' '}' >> "$TMP/g3/reg-loc-call/ex/main.tf"
g3w loc-dup ex/main.tf "locals {
  region = \"eu-west-1\"
}
$AZL"
g3w loc-dup ex/other.tf 'locals {
  region = "eu-west-2"
}'
g3w loc-nonliteral ex/main.tf "locals {
  region = var.region
}
$AZL"
g3w loc-multiline ex/main.tf "locals {
  region = (
    \"eu-west-1\"
  )
}
$AZL"
g3w loc-path ex/main.tf "locals {
  region = { name = \"eu-west-1\" }
}
data \"aws_availability_zones\" \"z\" {
  region = local.region.name
}"
regm loc-other-dir '' 'data "aws_availability_zones" "z" {
  region = local.region
}'
printf '%s\n' 'locals {' '  region = "eu-west-1"' '}' >> "$TMP/g3/reg-loc-other-dir/ex/main.tf"
g3w loc-unlexed ex/main.tf "locals {
  region = \"eu-west-1\"
}
$AZL"
g3w loc-unlexed ex/broken.tf 'locals {
  x = <<EOT
  y
}'
g3w loc-ban ex/main.tf "locals {
  region = \"eu-west-1\"
}
$AZL"
: > "$TMP/g3/loc-ban/ex/x.tfvars"
# aws_region and aws_service_principal take any region; the s3-bucket file-system pattern
RFM='locals {
  region = try(data.aws_region.current[0].region, "")
}
data "aws_region" "current" {
  count  = var.create ? 1 : 0
  region = var.region
}
data "aws_service_principal" "efs" {
  service_name = "elasticfilesystem"
  region       = local.region
}'
for c in rfree-pass rfree-az; do
  g3w "$c" mod/main.tf "$RFM"; g3w "$c" mod/variables.tf "$VARS"
  g3w "$c" root/main.tf 'module "fs" {
  source = "../mod"
  region = var.region
}
variable "region" {
  default = null
}'
  g3w "$c" ex/main.tf 'module "m" {
  source = "../root"
}'
done
printf '%s\n' 'data "aws_availability_zones" "z" {' '  region = local.region' '}' >> "$TMP/g3/rfree-az/mod/main.tf"
# Final review cases: a local in a dot file, a local of the wrong directory for a call or a
# data block, and skip_region_validation in a second provider block with a variable region
g3w loc-dotfile ex/.x.tf 'locals {
  r = "us-east-1"
}'
g3w loc-dotfile ex/main.tf 'data "aws_availability_zones" "z" {
  region = local.r
}'
g3w loc-call-wrongdir ex/main.tf 'module "m" {
  source = "../mod"
  region = local.r
}'
g3w loc-call-wrongdir mod/main.tf 'data "aws_availability_zones" "z" {
  region = var.region
}'
g3w loc-call-wrongdir mod/v.tf 'variable "region" {
  default = null
}

locals {
  r = "us-east-1"
}'
g3w loc-data-wrongdir ex/main.tf 'locals {
  r = "us-east-1"
}
module "m" {
  source = "../mod"
}'
g3w loc-data-wrongdir mod/main.tf 'data "aws_availability_zones" "z" {
  region = local.r
}'
g3w prov-split ex/main.tf 'provider "aws" {
  region = "us-east-1"
}
provider "aws" {
  alias                  = "b"
  region                 = var.r
  skip_region_validation = true
}
variable "r" {}'
# The file ban: each banned name in scope turns a passing case into a hit.
for b in override.tf x_override.tf x.tfvars x.tfvars.json x.auto.tfvars x.auto.tfvars.json.bak x.tf.json; do
  for c in pol-plain prov-skip bus-defaults; do
    cp -R "$TMP/g3/$c" "$TMP/g3/ban-$c-$b"
    case "$c" in bus-*) : > "$TMP/g3/ban-$c-$b/mod/$b" ;; *) : > "$TMP/g3/ban-$c-$b/ex/$b" ;; esac
  done
done

newrun() { # a run directory holding a clone of upstream
  R="$(mktemp -d "$TMP/pr-review.XXXXXX")"
  git clone -q "$up" "$R/clone"
  echo "$R"
}

for sh in bash zsh; do
  command -v "$sh" > /dev/null 2>&1 || { echo "FAIL $sh: not installed"; fails=$((fails + 1)); continue; }
  run() { PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" "$@" 2>&1; }

  R="$(newrun)"
  out="$(run g0 "$R")"
  check "$sh: g0 saves a clean result" "$(has "$out" 'g0: 0 hits')"

  out="$(run plan "$R" 'bad name')"
  check "$sh: a profile outside the pattern is not opted in" "$(has "$out" 'plan pass not run: profile not opted in')"
  out="$(PATH="$TMP/noaws:/usr/bin:/bin" "$sh" "$PP" plan "$R" demo --role-arn "$ROLE" examples/ok 2>&1)"
  check "$sh: a missing tool stops the pass with a note" "$(has "$out" 'plan pass not run: aws missing')"
  out="$(AWSVER=1.29.0 run plan "$R" demo --role-arn "$ROLE" examples/ok)"
  check "$sh: an AWS CLI before version 2 stops the pass with a note" \
    "$(has "$out" 'plan pass not run: AWS CLI version 2 missing')"
  out="$(run plan /tmp demo --role-arn "$ROLE" examples/ok)"
  check "$sh: a path that is not a run directory is refused" "$(lacks "$out" 'example:')"

  # The default pass's init left a lock file naming a provider outside the allowlist.
  printf 'provider "registry.terraform.io/hashicorp/null" {\n}\n' > "$R/clone/examples/ok/.terraform.lock.hcl"
  mkdir -p "$R/clone/examples/ok/.terraform"
  : > "$TMP/tf.log"
  out="$(run plan "$R" demo --role-arn "$ROLE" examples/ok examples/gate examples/err examples/leak)"
  check "$sh: planned, with the summary line kept" \
    "$(has "$out" 'plan: planned | Plan: 1 to add, 0 to change, 0 to destroy.')"
  check "$sh: the default pass's lock file is not read" "$(lacks "$out" 'hashicorp/null')"
  check "$sh: a scope line on success, clone and downloaded" \
    "$(has "$out" 'scope: examples/ok downloaded/s3')"
  check "$sh: a modules line on success" \
    "$(has "$out" 'modules: s3 registry.terraform.io/terraform-aws-modules/s3-bucket/aws 4.1.0')"
  check "$sh: a gate stops the example before init" \
    "$(has "$out" 'plan: plan gate G3 examples/gate/main.tf:1 (1 hits)')"
  check "$sh: a gated example still prints its scope" "$(has "$out" 'scope: examples/gate')"
  check "$sh: the clone root is written as a dot, never as a local path" "$(has "$out" 'scope: . examples/err')"
  check "$sh: no local path in the record" "$(lacks "$out" "$TMP")"
  check "$sh: the gate hit is printed for the log" \
    "$(has "$out" 'gate-hit G3 examples/gate/main.tf:1')"
  check "$sh: no terraform call in the gated example" "$(lacks "$(cat "$TMP/tf.log")" 'gate ')"
  check "$sh: a code error keeps its first line with the account redacted" \
    "$(has "$out" 'plan: code-error | Error: bucket <account> is not valid')"
  check "$sh: no base given: base not available" "$(has "$out" 'base: not available')"
  check "$sh: a block holding an exported credential value keeps only its class" \
    "$(has "$out" 'plan: code-error')"
  check "$sh: the credential value never leaves the pass" "$(lacks "$out" 's3cr3t')"
  out2="$(run plan "$R" demo --role-arn "$ROLE" examples/split)"
  check "$sh: a credential value split across lines still keeps only its class" \
    "$(has "$out2" 'plan: code-error')"
  check "$sh: no part of a split credential value leaves the pass" \
    "$(printf '%s\n' "$out2" | grep -E 's3cr3t|ue-xyz' > /dev/null && echo 1 || echo 0)"
  check "$sh: the summary counts planned and exceptions apart" \
    "$(has "$out" 'plan summary: 4 examples, 1 planned, 0 exceptions, 3 other')"
  check "$sh: the pass's own files are removed at the end" "$(test ! -e "$R/plan"; echo $?)"
  check "$sh: the clone stays" "$(test -d "$R/clone/examples"; echo $?)"
  check "$sh: an uncommitted lock file is removed" \
    "$(test ! -e "$R/clone/examples/ok/.terraform.lock.hcl"; echo $?)"

  # The review role: no role, no pass; a session on it or nothing, then the write probe.
  log="$(cat "$TMP/aws.log" 2>/dev/null)"
  check "$sh: the session is assumed on the review role with the profile, for 900 seconds" \
    "$(printf '%s\n' "$log" | grep -- '--profile=demo --role-arn arn:aws:iam::210987654321:role/modulestf-review --role-session-name modulestf-plan-pass --duration-seconds 900 --policy {' > /dev/null && echo 0 || echo 1)"
  check "$sh: the session carries the pinned policy" "$(printf '%s\n' "$log" | grep -F '"Sid":"NoDataReads"' > /dev/null && echo 0 || echo 1)"
  check "$sh: the profile's own credentials are never exported" "$(lacks "$log" 'export-credentials')"
  check "$sh: the role ARN and its account never leave the pass" "$(printf '%s\n' "$out" | grep -E 'modulestf-review|210987654321' > /dev/null && echo 1 || echo 0)"
  R="$(newrun)"; run g0 "$R" > /dev/null
  out="$(run plan "$R" demo examples/ok)"
  check "$sh: no review role, no plan pass" "$(has "$out" 'plan pass not run: no review role')"
  out="$(run plan "$R" demo --role-arn 'arn:aws:iam::21098765432:role/x' examples/ok)"
  check "$sh: a role ARN outside the pattern is no review role" "$(has "$out" 'plan pass not run: no review role')"
  for c in "fail ok denied|session: not issued|the session cannot be issued" \
    "ok throttled denied|identity check: throttled|the identity check is throttled" \
    "ok expired denied|identity check: expired token|the identity check sees an expired token" \
    "ok ok allowed|write probe: write allowed|the probe write is allowed (DryRunOperation)" \
    "ok ok offline|write probe: network|the probe gets another answer"; do
    R="$(newrun)"; run g0 "$R" > /dev/null; : > "$TMP/tf.log"
    read -r sts ident probe <<< "${c%%|*}"; echo "$probe" > "$TMP/probe"; echo "$ident" > "$TMP/ident"
    why="${c#*|}"; why="${why%%|*}"
    out="$(AWSSTS="$sts" PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" plan "$R" demo --role-arn "$ROLE" examples/ok examples/err 2>&1)"
    check "$sh: ${c##*|}: the pass ends at credentials" "$(has "$out" 'plan: plan pass ended: credentials')"
    check "$sh: ${c##*|}: the record names the step: $why" "$(has "$out" "credentials: $why")"
    check "$sh: ${c##*|}: the next example is not reached" "$(has "$out" 'not reached: examples/err')"
    check "$sh: ${c##*|}: the next example gets no block" "$(lacks "$out" 'example: examples/err')"
    check "$sh: ${c##*|}: the answer's account never reaches the record" "$(lacks "$out" '210987654321')"
    check "$sh: ${c##*|}: no plan runs" "$(lacks "$(cat "$TMP/tf.log")" 'ok plan')"
  done
  rm -f "$TMP/probe" "$TMP/ident"

  # The merge base re-run of a code error.
  R="$(newrun)"
  run g0 "$R" > /dev/null
  out="$(run plan "$R" demo --role-arn "$ROLE" --base "$BASE" examples/err examples/leak)"
  check "$sh: a code error present at base reproduces there" "$(has "$out" 'base: reproduces at base')"
  check "$sh: an example absent at base is new" "$(has "$out" 'base: new under this change (absent at base)')"
  check "$sh: the base worktree's G0 result is saved" "$(test -f "$R/g0-base.txt"; echo $?)"
  R="$(newrun)"
  run g0 "$R" > /dev/null
  out="$(run plan "$R" demo --role-arn "$ROLE" --base "--upload-pack=touch $TMP/pwned" examples/err)"
  check "$sh: a base that is not a full SHA is not available" "$(has "$out" 'base: not available')"
  check "$sh: a base is never read as a git option" "$(test ! -e "$TMP/pwned"; echo $?)"
  out="$(run plan "$R" demo --role-arn "$ROLE" --base "${BASE%????}" examples/err)"
  check "$sh: a short SHA is not available either" "$(has "$out" 'base: not available')"

  # No saved G0 result: every example fails closed.
  R="$(newrun)"
  out="$(run plan "$R" demo --role-arn "$ROLE" examples/ok)"
  check "$sh: a missing G0 result fails closed" "$(has "$out" 'plan: plan gate G0 not evaluated')"

  # A clone-wide G0 hit stops every example.
  R="$(newrun)"
  : > "$R/clone/terraform.tfvars"
  # The laptop relaxations of G3, case by case: an empty output is a pass
  R3="$(newrun)"; cp -R "$TMP/g3" "$R3/clone/g3"
  g3() { # case, [mode]
    if [ "${2:-clone}" = downloaded ]; then
      find "$R3/clone/g3/$1/mod" -name '*.tf' | sort | PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" gates "$R3" laptop downloaded 2>&1
    else
      run scope "$R3" "$R3/clone/g3/$1/ex" | PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" gates "$R3" laptop clone "$R3/clone/g3/$1/ex" 2>&1
    fi
  }
  for c in pol-plain pol-partition free-arn free-doc bus-root bus-defaults bus-null-region bus-nn-safe \
    bus-region-fake prov-skip; do
    out="$(g3 "$c")"
    check "$sh: laptop mode admits $c" "$(test -z "$out"; echo $?)"
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  for c in pol-account pol-anchor pol-var pol-interp pol-name pol-provider pol-region pol-for-each \
    pol-heredoc pol-multi-count pol-dotdot pol-dot pol-brace pol-comment pol-long free-file free-unlexed \
    bus-root-var bus-null-name bus-nn-unsafe bus-nn-var bus-nonliteral bus-arn bus-slash \
    bus-region-host bus-two-calls bus-unresolved bus-zero bus-nested bus-extra bus-dup-name \
    prov-skip-var prov-skip-unknown prov-region-true prov-endpoints; do
    check "$sh: laptop mode refuses $c" "$(g3 "$c" | grep '^class: plan gate G3 ' > /dev/null; echo $?)"
  done
  for c in bus-unresolved bus-two-calls bus-nested; do
    check "$sh: $c is a hit at the event bus itself" "$(g3 "$c" | grep -x "G3 $R3/clone/g3/$c/mod/main.tf:1" > /dev/null; echo $?)"
  done
  check "$sh: the event bus is always a hit in downloaded mode" \
    "$(g3 bus-defaults downloaded | grep -x "G3 $R3/clone/g3/bus-defaults/mod/main.tf:1" > /dev/null; echo $?)"
  out="$(run scope "$R3" "$R3/clone/g3/bus-defaults/ex" | PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" gates "$R3" laptop clone 2>&1)"
  check "$sh: without the example root the event bus is a hit" \
    "$(has "$out" "G3 $R3/clone/g3/bus-defaults/mod/main.tf:1")"
  for c in prov-region-true-literal reg-root-literal reg-root-null reg-root-absent reg-mod-default \
    reg-mod-call-literal reg-mod-literal; do
    out="$(g3 "$c")"
    check "$sh: laptop mode admits $c" "$(test -z "$out"; echo $?)"
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  for c in prov-region-true-var prov-region-true-s3 prov-region-true-comment reg-root-var reg-root-s3 \
    reg-root-local reg-root-interp reg-root-data reg-root-twice reg-mod-call-s3 reg-mod-call-local \
    reg-mod-local reg-mod-zero reg-mod-nested reg-mod-ban reg-unlexed; do
    check "$sh: laptop mode refuses $c" "$(g3 "$c" | grep '^class: plan gate G3 ' > /dev/null; echo $?)"
  done
  for c in reg-mod-zero reg-mod-nested reg-mod-ban reg-mod-call-s3; do
    check "$sh: $c is a hit at the data block" "$(g3 "$c" | grep -x "G3 $R3/clone/g3/$c/mod/main.tf:1" > /dev/null; echo $?)"
  done
  check "$sh: a literal region passes in downloaded mode" "$(test -z "$(g3 reg-mod-literal downloaded)"; echo $?)"
  check "$sh: var.region is a hit in downloaded mode" \
    "$(g3 reg-mod-default downloaded | grep -x "G3 $R3/clone/g3/reg-mod-default/mod/main.tf:1" > /dev/null; echo $?)"
  check "$sh: the file ban keeps skip_region_validation = true a hit" \
    "$(cp -R "$R3/clone/g3/prov-region-true-literal" "$R3/clone/g3/ban-region-true" && : > "$R3/clone/g3/ban-region-true/ex/x.tfvars" && g3 ban-region-true | grep '^G3 ' > /dev/null; echo $?)"
  for c in crlf-arg crlf-call ff-arg nospace-call mention; do
    check "$sh: laptop mode refuses $c" "$(g3 "$c" | grep '^class: plan gate ' > /dev/null; echo $?)"
  done
  check "$sh: a call written against its label is still enumerated" \
    "$(g3 nospace-call | grep -x "G3 $R3/clone/g3/nospace-call/mod/main.tf:1" > /dev/null; echo $?)"
  for c in loc-root loc-bus-root reg-loc-call; do
    out="$(g3 "$c")"
    check "$sh: laptop mode admits $c" "$(test -z "$out"; echo $?)"
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  for c in loc-dup loc-nonliteral loc-multiline loc-path loc-unlexed loc-ban; do
    check "$sh: laptop mode refuses $c" \
      "$(g3 "$c" | grep -x "G3 $R3/clone/g3/$c/ex/main.tf:4" > /dev/null || g3 "$c" | grep -x "G3 $R3/clone/g3/$c/ex/main.tf:6" > /dev/null; echo $?)"
  done
  check "$sh: a local of another directory does not resolve" \
    "$(g3 reg-loc-other-dir | grep -x "G3 $R3/clone/g3/reg-loc-other-dir/mod/main.tf:1" > /dev/null; echo $?)"
  out="$(g3 rfree-pass)"
  check "$sh: aws_region and aws_service_principal take any region" "$(test -z "$out"; echo $?)"
  [ -z "$out" ] || printf '%s\n' "$out"
  check "$sh: aws_availability_zones with the same region is still a hit" \
    "$(g3 rfree-az | grep -x "G3 $R3/clone/g3/rfree-az/mod/main.tf:12" > /dev/null; echo $?)"
  for c in loc-dotfile loc-call-wrongdir loc-data-wrongdir prov-split; do
    check "$sh: laptop mode refuses $c" "$(g3 "$c" | grep '^class: plan gate G3 ' > /dev/null; echo $?)"
  done
  check "$sh: a dot file is not in the scope" "$(run scope "$R3" "$R3/clone/g3/loc-dotfile/ex" | grep -F '/.x.tf' > /dev/null; test $? -eq 1; echo $?)"
  for b in override.tf x_override.tf x.tfvars x.tfvars.json x.auto.tfvars x.auto.tfvars.json.bak x.tf.json; do
    for c in pol-plain prov-skip bus-defaults; do
      check "$sh: $b in scope turns off the relaxation for $c" \
        "$(g3 "ban-$c-$b" | grep '^G3 ' > /dev/null; echo $?)"
    done
  done

  run g0 "$R" > /dev/null
  out="$(run plan "$R" demo --role-arn "$ROLE" examples/ok)"
  check "$sh: a clone-wide G0 hit stops the example" \
    "$(has "$out" 'plan: plan gate G0 terraform.tfvars (1 hits)')"

  # Thirteen examples: no cap on the number, the budget is the only bound.
  R="$(newrun)"
  run g0 "$R" > /dev/null
  set -- examples/gate examples/gate examples/gate examples/gate examples/gate examples/gate \
    examples/gate examples/gate examples/gate examples/gate examples/gate examples/gate examples/ok
  : > "$TMP/tf.log"
  out="$(run plan "$R" demo --role-arn "$ROLE" "$@")"
  check "$sh: no cap of 12 examples: the thirteenth is planned" \
    "$([ "$(has "$out" 'plan: budget')" = 1 ] && [ "$(has "$out" 'plan: planned | Plan: 1 to add, 0 to change, 0 to destroy.')" = 0 ]; echo $?)"
  set --
  # Saved plans: the plan writes one with -out, and only a planned example's is read back,
  # by terraform show -json with no credentials, into its addresses file.
  check "$sh: the plan is saved and read back with show" \
    "$(grep -qx 'ok plan' "$TMP/tf.log" && grep -qx 'ok show' "$TMP/tf.log" && ! grep -q 'show with credentials' "$TMP/tf.log"; echo $?)"
  A="$R/plan-addresses/addresses-13.json"
  check "$sh: the addresses file of the planned example: config addresses, attribute names only" \
    "$(jq -e '{addresses, attributes, module_calls} | .addresses |= map(select(contains("data.") | not)) | .attributes |= with_entries(select(.key | contains("data.") | not))
      | . == {addresses:["aws_kms_key.this","module.s3.aws_s3_bucket.this"], attributes:{"aws_kms_key.this":["policy"],"module.s3.aws_s3_bucket.this":["arn","bucket","logging","region","versioning"]}, module_calls:{"local":"../../"}}' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: the data sources the plan read, matched to the configuration at their module path; no orphan, managed state entry or malformed address" \
    "$(jq -e '[.addresses[] | select(contains("data."))] == ["data.aws_iam_policy_document.deferred","data.aws_iam_policy_document.planned_only",
      "data.aws_iam_policy_document.this","data.aws_secretsmanager_secret_version.s","data.aws_x.map","module.s3.data.aws_iam_policy_document.bucket"]
      and (.addresses | index("aws_s3_bucket.stale") == null)' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: a data source lists the top-level names of its values, a map by its own name, never a key inside it" \
    "$(jq -e '.attributes["data.aws_x.map"] == ["filter","name"] and .attributes["data.aws_iam_policy_document.this"] == ["json","statement"]
      and .attributes["data.aws_iam_policy_document.planned_only"] == ["policy_id"] and .attributes["module.s3.data.aws_iam_policy_document.bucket"] == ["json"]' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: a deferred data source read keeps its resource change names, merged with its planned_values entry" \
    "$(jq -e '.attributes["data.aws_iam_policy_document.deferred"] == ["json","statement"]' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: a data source attribute its sensitive_values marks is listed sensitive, by name" \
    "$(jq -e '.sensitive["data.aws_secretsmanager_secret_version.s"] == ["secret_string"] and .sensitive["data.aws_x.map"] == []
      and .sensitive["data.aws_iam_policy_document.this"] == []' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: no value or map key of a data source reaches the addresses file" "$(lacks "$(cat "$A")" leaked)"
  check "$sh: the addresses file keys, in order, the head commit and the example last" \
    "$(jq -e 'keys_unsorted == ["addresses","attributes","module_calls","sensitive","head_sha","example"] and .example == "examples/ok"' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: the head commit the example was planned at" \
    "$(jq -e --arg h "$(git -C "$R/clone" rev-parse HEAD)" '.head_sha == $h and ($h | test("^[0-9a-f]{40}$"))' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: a sensitive attribute and a nested sensitive block are listed by top-level name; all-false and not sensitive are not" \
    "$(jq -e '.sensitive["module.s3.aws_s3_bucket.this"] == ["bucket","logging"]' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: an instance with no sensitive bit marks every attribute of its address sensitive" \
    "$(jq -e '.sensitive["aws_kms_key.this"] == ["policy"]' "$A" > /dev/null 2>&1; echo $?)"
  check "$sh: no addresses file for an example that did not plan" "$([ ! -s "$R/plan-addresses/addresses-1.json" ]; echo $?)"
  check "$sh: the saved plans go with the pass's own files" "$(test ! -e "$R/plan"; echo $?)"

  # Modes. Runner mode relaxes the code-execution gates and is refused outside a container.
  R="$(newrun)"
  cp -R "$TMP/rt" "$R/clone/rt"
  gates() { printf '%s\n' "$R/clone/rt/$2.tf" | PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" gates "$R" "$1" clone 2>&1; }
  for t in endpoints comment-brace hash-in-string both-tricks renamed dynamic-role profile backend cloud \
    open-heredoc open-string lookalike git-source github-lookalike unquoted-label role-variable \
    role-interpolated role-extra role-and-endpoints role-twice docker-and-backend \
    build-in-docker-and-backend adj-data adj-provider adj-module cr-heredoc ff-heredoc nbsp-heredoc ls-heredoc; do
    check "$sh: runner mode refuses $t" "$(gates runner "$t" | grep '^class: plan gate' > /dev/null; echo $?)"
  done
  out="$(gates runner ok)"
  check "$sh: runner mode allows code execution, file functions and github sources" "$(test -z "$out"; echo $?)"
  [ -z "$out" ] || printf '%s\n' "$out"
  check "$sh: laptop mode still refuses them" "$(test -n "$(gates laptop ok)"; echo $?)"
  out="$(gates runner role-fixed)"
  check "$sh: runner mode records a fixed role as an exception" \
    "$(has "$out" 'class: exception: example assumes a role in another account')"
  out="$(gates runner docker)"
  check "$sh: runner mode records the Docker provider as an exception" \
    "$(has "$out" 'class: exception: needs a Docker daemon')"
  out="$(gates runner build-in-docker)"
  check "$sh: runner mode records build_in_docker = true as an exception" \
    "$(has "$out" 'class: exception: needs a Docker daemon')"
  out="$(printf '%s\n' "$R/clone/rt/build-in-docker.tf" | PATH="$TMP/bin:/usr/bin:/bin" "$sh" "$PP" gates "$R" runner downloaded 2>&1)"
  check "$sh: runner mode records build_in_docker in a downloaded module" \
    "$(has "$out" 'class: exception: needs a Docker daemon')"
  for t in build-in-docker-var build-in-docker-false build-in-docker-nested; do
    check "$sh: runner mode records nothing for $t" "$(test -z "$(gates runner "$t")"; echo $?)"
  done
  check "$sh: laptop mode records no build_in_docker exception" \
    "$(gates laptop build-in-docker | grep exception > /dev/null; test $? -eq 1; echo $?)"
  for t in adj-data adj-provider adj-module cr-heredoc ff-heredoc; do
    check "$sh: laptop mode refuses $t" "$(gates laptop "$t" | grep '^class: plan gate' > /dev/null; echo $?)"
  done
  check "$sh: laptop mode refuses a fixed role" "$(gates laptop role-fixed | grep '^class: plan gate G3' > /dev/null; echo $?)"
  check "$sh: laptop mode refuses the Docker provider" "$(gates laptop docker | grep '^class: plan gate G1' > /dev/null; echo $?)"
  run g0 "$R" > /dev/null
  out="$(run plan "$R" demo --role-arn "$ROLE" examples/ok)"
  check "$sh: laptop mode is the default and is recorded" "$(has "$out" 'plan pass mode: laptop')"
  out="$(run plan "$R" demo --role-arn "$ROLE" --mode other examples/ok)"
  check "$sh: an unknown mode stops the pass" "$(has "$out" 'plan pass not run: mode unknown')"
  if [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ]; then
    out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner examples/ok)"
    check "$sh: runner mode outside a container stops the pass" \
      "$(has "$out" 'plan pass not run: runner mode outside a container')"
    out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --phase init examples/ok)"
    check "$sh: a runner phase outside a container stops the pass" \
      "$(has "$out" 'plan pass not run: runner mode outside a container')"
  fi
  # The runner phases themselves run only in a container: plan-runner/smoke.sh covers them
  out="$(run plan "$R" demo --role-arn "$ROLE" --phase init examples/ok)"
  check "$sh: a phase needs runner mode" "$(has "$out" 'plan pass not run: phase needs runner mode')"
  out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --phase plan examples/ok)"
  check "$sh: the plan phase needs an index" \
    "$(has "$out" 'plan pass not run: phase plan needs --index and one example')"
  out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --phase plan --index 1 examples/ok examples/err)"
  check "$sh: the plan phase takes one example" \
    "$(has "$out" 'plan pass not run: phase plan needs --index and one example')"
  # Runner mode has no example cap; its bound is the runner's budget, which only it may set
  out="$(run plan "$R" demo --role-arn "$ROLE" --budget 600 examples/ok)"
  check "$sh: a budget needs runner mode" "$(has "$out" 'plan pass not run: budget needs runner mode')"
  for b in 0 60s -1 12345678; do
    out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --budget "$b" examples/ok)"
    check "$sh: budget $b is refused" "$(has "$out" 'plan pass not run: budget not a number of seconds')"
  done
  for ph in base-init base-plan; do
    out="$(run plan "$R" demo --role-arn "$ROLE" --phase "$ph" --index 1 examples/err)"
    check "$sh: phase $ph needs runner mode" "$(has "$out" 'plan pass not run: phase needs runner mode')"
    out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --phase "$ph" examples/err)"
    check "$sh: phase $ph needs an index" \
      "$(has "$out" "plan pass not run: phase $ph needs --index and one example")"
  done
  out="$(run plan "$R" demo --role-arn "$ROLE" --mode runner --phase other examples/ok)"
  check "$sh: an unknown phase stops the pass" "$(has "$out" 'plan pass not run: phase unknown')"
done

# Negative self-check of the relaxations: each weakened copy of the script must let its case
# through, and the real script must refuse it.
mkdir -p "$TMP/mut"
R3="$(newrun)"; cp -R "$TMP/g3" "$R3/clone/g3"
mg() { # script, case
  bash "$PP" scope "$R3" "$R3/clone/g3/$2/ex" | PATH="$TMP/bin:/usr/bin:/bin" bash "$1" gates "$R3" laptop clone "$R3/clone/g3/$2/ex" 2>&1
}
mutate() { # name, perl substitution, case...
  local m="$TMP/mut/$1.sh" c
  perl -pe "$2" "$PP" > "$m"
  check "mutation $1 changes the script" "$(cmp -s "$PP" "$m"; test $? -eq 1; echo $?)"
  for c in "${@:3}"; do
    check "mutation $1 is caught by $c" "$([ -n "$(mg "$PP" "$c")" ] && [ -z "$(mg "$m" "$c")" ]; echo $?)"
  done
}
mutate arn-anchor 's/qr\{\\Aarn:\(\?:aws/qr{arn:(?:aws/' pol-anchor
mutate dot-segments 's/grep \{ \$_ eq "\." \|\| \$_ eq "\.\." \}/grep { 0 }/' pol-dotdot pol-dot
mutate name-class 's/\$NAMEOK = qr\{\\A\[A-Za-z0-9\._-\]/\$NAMEOK = qr{\\A[A-Za-z0-9._:\/-]/' bus-arn bus-slash
mutate region-check 's/hit\("G3", \$f, \$M\{\$f\}, \$b->\[3\]\) unless region_ok/hit("G3", \$f, \$M{\$f}, \$b->[3]) if 0 \&\& region_ok/' \
  reg-root-s3 reg-root-local reg-mod-call-s3
mutate region-true 's/next if !\$ban && \$rlit && /next if !\$ban \&\& /' prov-region-true-s3 prov-region-true-var
mutate every-mention 's/\$rel\{\$y\}\[1\] == \$seen\{\$y\}/1/' mention
mutate local-once 's/\$v && \$v->\{n\} == 1 && lit/\$v \&\& lit/' loc-dup
mutate region-free-all 's/&& \$rfree\{\$b->\[0\]\[0\]\}/\&\& 1/' rfree-az

# plan-session.sh: one fixed reason on standard error per failure class, nothing on standard output.
SESS="${PP%/*}/plan-session.sh"
sess() { PATH="$TMP/bin:/usr/bin:/bin" AWSSTS="${1:-ok}" bash "$SESS" "${@:2}" 2> "$TMP/sess.err"; }
o="$(sess ok 'bad name' "$ROLE" modulestf-x)"
check "plan-session: bad input names its class, prints nothing" "$([ -z "$o" ] && grep -qx 'plan-session: bad input: profile name' "$TMP/sess.err" && echo 0 || echo 1)"
o="$(sess ok demo 'arn:aws:iam::1:role/x' modulestf-x)"
check "plan-session: a bad role ARN is bad input" "$(grep -qx 'plan-session: bad input: review role ARN' "$TMP/sess.err" && echo 0 || echo 1)"
o="$(sess fail demo "$ROLE" modulestf-x)"
check "plan-session: a failed assume-role names its class, prints nothing" "$([ -z "$o" ] && grep -qx 'plan-session: assume-role failed or timed out' "$TMP/sess.err" && echo 0 || echo 1)"
o="$(sess empty demo "$ROLE" modulestf-x)"
check "plan-session: an answer without credentials names its class, prints nothing" "$([ -z "$o" ] && grep -qx 'plan-session: bad output: no session credentials in the assume-role answer' "$TMP/sess.err" && echo 0 || echo 1)"
o="$(sess ok demo "$ROLE" modulestf-x)"
check "plan-session: a session prints the three values only" "$(printf '%s\n' "$o" | jq -e 'keys == ["AccessKeyId","SecretAccessKey","SessionToken"]' > /dev/null && echo 0 || echo 1)"

# The session policy: valid JSON within the 2,048 characters AssumeRole accepts, allowing no
# write and denying the data reads by name.
POL="${PP%/*}/plan-session-policy.json"
check "session policy: parses and fits AssumeRole's 2,048 characters" "$(n="$(jq -c . "$POL" | wc -c)" && [ "$n" -le 2049 ] && echo 0 || echo 1)"
check "session policy: allows only Describe, List and Get actions and GetCallerIdentity" \
  "$(jq -e '[.Statement[] | select(.Effect == "Allow") | .Action[] | test("^[a-z0-9-]+:(Describe|List|Get)[A-Za-z]*[*]?$")] | all' "$POL" > /dev/null && echo 0 || echo 1)"
for a in s3:GetObject secretsmanager:GetSecretValue ssm:GetParameter kms:Decrypt lambda:GetFunctionConfiguration \
  ecs:DescribeTaskDefinition ec2:DescribeLaunchTemplateVersions ec2:DescribeInstanceAttribute cloudfront:GetFunction \
  iam:GetAccountAuthorizationDetails; do
  check "session policy: denies $a" "$(jq -e --arg a "$a" '[.Statement[] | select(.Effect == "Deny") | .Action[] | rtrimstr("*") as $p | $a | startswith($p)] | any' "$POL" > /dev/null && echo 0 || echo 1)"
done

# hosted-record.sh: a finished run-pass.sh record reduced to plan-hosted.json, classes and
# counts only, on fixture record directories.
HR="${PP%/*}/plan-runner/hosted-record.sh"
HH=0123456789abcdef0123456789abcdef01234567 HM=89abcdef0123456789abcdef0123456789abcdef
hrec() { # name, then plan-pass.txt lines between the header and the summary -> a record directory
  local d="$TMP/hr-$1"; shift
  mkdir -p "$d"
  { printf '%s\n' 'plan pass mode: runner' 'plan pass budget: 90 minutes' "$@"
    echo 'plan summary: 1 examples, 0 planned, 0 exceptions, 1 other'; } > "$d/plan-pass.txt"
  printf '%s\n' secret-host.example.com:443 other-host.example.net:443 sts.us-east-1.amazonaws.com:8443 > "$d/plan-refused-hosts.txt"
  echo "$d"
}
hr() { rm -f "$TMP/hr.json"; bash "$HR" --record "$1" --head "$HH" --merge-base "$HM" --out "$TMP/hr.json" 2> "$TMP/hr.err"; echo $?; }
hq() { jq -e "$1" "$TMP/hr.json" > /dev/null 2>&1 && echo 0 || echo 1; }
good="$(hrec good 'host example 1: examples/complete' 'example: examples/complete' \
  'plan: planned | Plan: 3 to add, 1 to change, 0 to destroy.' 'scope: examples/complete .' \
  'modules: s3 registry.terraform.io/terraform-aws-modules/s3-bucket/aws 4.1.0' \
  'host example 2: examples/broken' 'example: examples/broken' \
  'plan: code-error | Error: bucket <account> is not reachable at secret-host.example.com' 'base: reproduces at base' \
  'host example 3: examples/gated' 'plan: plan gate G2 examples/gated/main.tf:3 (1 hits)' \
  'host example 4: examples/late' 'plan: budget' \
  'host example 5: examples/nochange' 'plan: planned-no-changes' \
  'host example 6: examples/imports' 'plan: planned | Plan: 2 to import, 1 to add, 0 to change, 4 to destroy.' \
  'host example 7: examples/new' 'plan: code-error' 'base: new under this change (absent at base)')"
echo '{"addresses":["module.s3.aws_s3_bucket.this","x[\"k\"]"],"attributes":{"module.s3.aws_s3_bucket.this":["bucket","Name"],"y":["z"]},"sensitive":{"module.s3.aws_s3_bucket.this":["bucket"]}}' > "$good/addresses-1.json"
echo '{"addresses":["aws_b.c"]}' > "$good/addresses-2.json"
echo '{"addresses":["data.aws_iam_policy_document.this","module.s3.data.aws_iam_policy_document.bucket","data.aws_bad","module.m.data.x"],"attributes":{"data.aws_iam_policy_document.this":["json","statement"],"data.aws_bad":["json"]}}' > "$good/addresses-5.json"
check "hosted-record: a good record is reduced" "$(hr "$good")"
check "hosted-record: the exact top-level keys, head and merge base" \
  "$(hq "keys == [\"examples\",\"head\",\"merge_base\",\"refused_hosts\",\"schema_version\"] and .schema_version == 1 and .head == \"$HH\" and .merge_base == \"$HM\"")"
check "hosted-record: one entry per example, in order" \
  "$(hq '[.examples[].path] == ["examples/complete","examples/broken","examples/gated","examples/late","examples/nochange","examples/imports","examples/new"]')"
check "hosted-record: planned keeps the three counts only" \
  "$(hq '.examples[0] == {path: "examples/complete", head: {class: "planned", plan: {add: 3, change: 1, destroy: 0}}, base: null,
    addresses: ["module.s3.aws_s3_bucket.this"], attributes: {"module.s3.aws_s3_bucket.this": ["bucket"]}}')"
# host-pass.sh's rules for plan-hosted.json, taken from the script: the reduced record passes,
# with its addresses; an address or attribute outside its pattern fails.
HPJ="$(sed -n "/^PLAN_HOSTED_JQ='\$/,/^'\$/p" "${PP%/*}/host-pass.sh" | sed '1d;$d')"
hp() { jq -n -r --arg head "$HH" --slurpfile p "$1" --slurpfile h "$TMP/hp-host.json" --slurpfile f "$TMP/hp-files.json" "$HPJ"; }
echo "{\"prefix\": \"\", \"merge_base\": \"$HM\"}" > "$TMP/hp-host.json"; echo '[]' > "$TMP/hp-files.json"
check "host-pass: the reduced record with its addresses is accepted" "$([ "$(hp "$TMP/hr.json")" = ok ] && echo 0 || echo 1)"
jq '.examples[0].addresses += ["a b"]' "$TMP/hr.json" > "$TMP/hp-bad1.json"
check "host-pass: an address outside the pattern is refused" "$([ "$(hp "$TMP/hp-bad1.json")" = "plan record content" ] && echo 0 || echo 1)"
jq '.examples[0].attributes.other = ["x"]' "$TMP/hr.json" > "$TMP/hp-bad2.json"
check "host-pass: attributes of an address not planned are refused" "$([ "$(hp "$TMP/hp-bad2.json")" = "plan record content" ] && echo 0 || echo 1)"
jq 'del(.examples[0].addresses)' "$TMP/hr.json" > "$TMP/hp-bad3.json"
check "host-pass: an example without addresses is refused" "$([ "$(hp "$TMP/hp-bad3.json")" = "plan record content" ] && echo 0 || echo 1)"
check "hosted-record: data source addresses are kept, a malformed data address dropped" \
  "$(hq '.examples[4].addresses == ["data.aws_iam_policy_document.this","module.s3.data.aws_iam_policy_document.bucket"]
    and .examples[4].attributes == {"data.aws_iam_policy_document.this":["json","statement"]}')"
for bad in data.aws_bad module.m.data.x data.data.a.b 'data.a.b c'; do
  jq --arg a "$bad" '.examples[4].addresses += [$a]' "$TMP/hr.json" > "$TMP/hp-bad4.json"
  check "host-pass: a malformed data address is refused ($bad)" "$([ "$(hp "$TMP/hp-bad4.json")" = "plan record content" ] && echo 0 || echo 1)"
done
# Negative self-check: a copy of host-pass.sh or hosted-record.sh without the address grammar
# takes the malformed data address.
jq '.examples[4].addresses += ["data.aws_bad"]' "$TMP/hr.json" > "$TMP/hp-bad4.json"
HPM="$(sed -n "/^PLAN_HOSTED_JQ='\$/,/^'\$/p" "${PP%/*}/host-pass.sh" | sed '1d;$d' | perl -pe 's/\(\?!data\\\\\.\|module\\\\\.\)//')"
check "mutation host-pass-grammar changes the rule" "$([ "$HPM" != "$HPJ" ]; echo $?)"
check "mutation host-pass-grammar is caught" \
  "$([ "$(jq -n -r --arg head "$HH" --slurpfile p "$TMP/hp-bad4.json" --slurpfile h "$TMP/hp-host.json" --slurpfile f "$TMP/hp-files.json" "$HPM")" = ok ]; echo $?)"
perl -pe 's/\(\?!data\\\\\.\|module\\\\\.\)//' "$HR" > "$TMP/hr-mut.sh"
check "mutation hosted-record-grammar changes the script" "$(cmp -s "$HR" "$TMP/hr-mut.sh"; test $? -eq 1; echo $?)"
cp "$TMP/hr.json" "$TMP/hr-real.json"; rm -f "$TMP/hr.json"
bash "$TMP/hr-mut.sh" --record "$good" --head "$HH" --merge-base "$HM" --out "$TMP/hr.json" 2> /dev/null
check "mutation hosted-record-grammar is caught" "$(hq '.examples[4].addresses | index("data.aws_bad")')"
mv "$TMP/hr-real.json" "$TMP/hr.json"
check "hosted-record: an import count is not kept" "$(hq '.examples[5].head.plan == {add: 1, change: 0, destroy: 4}')"
check "hosted-record: a code-error keeps its class and its base result" \
  "$(hq '.examples[1] == {path: "examples/broken", head: {class: "code-error", plan: null}, base: {class: "reproduces at base", plan: null},
    addresses: [], attributes: {}}')"
check "hosted-record: a gate hit is reduced to its gate" "$(hq '.examples[2].head.class == "plan gate G2"')"
check "hosted-record: budget, no changes and absent at base are kept as classes" \
  "$(hq '.examples[3].head.class == "budget" and .examples[4].head == {class: "planned-no-changes", plan: null} and .examples[6].base.class == "new under this change (absent at base)"')"
check "hosted-record: the refused hosts are a count" "$(hq '.refused_hosts == 3')"
check "hosted-record: no host name, kept line or file name leaks" \
  "$(grep -qE 'example\.com|example\.net|amazonaws|Error|account|main\.tf|registry|s3-bucket|budget: 90' "$TMP/hr.json" && echo 1 || echo 0)"
check "hosted-record: an --out in a missing directory is a usage error" "$(e="$(bash "$HR" --record "$good" --head "$HH" --merge-base "$HM" --out "$TMP/no-such-dir/hr.json" 2>&1)"; [ $? = 2 ] && [ "$e" = "hosted-record: --out must be in an existing directory" ] && echo 0 || echo 1)"
check "hosted-record: an existing --out is refused" "$([ "$(bash "$HR" --record "$good" --head "$HH" --merge-base "$HM" --out "$TMP/hr.json" 2> /dev/null; echo $?)" = 2 ] && echo 0 || echo 1)"
hrefused() { # name, record directory, expected reason
  local rc; rc="$(hr "$2")"
  check "hosted-record: refuses $1" "$([ "$rc" = 1 ] && [ ! -e "$TMP/hr.json" ] && grep -qxF "hosted-record: refused: $3" "$TMP/hr.err" && echo 0 || echo 1)"
}
hrefused "a class outside the list" "$(hrec class 'host example 1: examples/a' 'plan: planned at secret-host.example.com')" "a class outside the list"
hrefused "a base result outside the list" "$(hrec base 'host example 1: examples/a' 'plan: code-error' 'base: deferred')" "a base result outside the list"
hrefused "a block with no plan line" "$(hrec noplan 'host example 1: examples/a' 'example: examples/a')" "a block with no plan line"
hrefused "a duplicate example path" "$(hrec dup 'host example 1: examples/a' 'plan: budget' 'host example 2: examples/a' 'plan: budget')" "a duplicate example path"
hrefused "a path outside the pattern" "$(hrec path 'host example 1: examples/../x' 'plan: budget')" "an example path outside the pattern"
hrefused "an example under a module root prefix" "$(hrec nested 'host example 1: modules/x/examples/a' 'plan: budget')" "an example path outside the pattern"
hrefused "a path that is not an example" "$(hrec notex 'host example 1: modules/a' 'plan: budget')" "an example path outside the pattern"
hrefused "host example lines out of order" "$(hrec order 'host example 2: examples/a' 'plan: budget')" "host example lines out of order"
d="$(hrec nosum 'host example 1: examples/a' 'plan: budget')"; sed -i.bak '$d' "$d/plan-pass.txt"; rm -f "$d/plan-pass.txt.bak"
hrefused "a record with no summary line" "$d" "the record has no summary line"
d="$(hrec laptop 'host example 1: examples/a' 'plan: budget')"; sed -i.bak 's/^plan pass mode: runner$/plan pass mode: laptop/' "$d/plan-pass.txt"; rm -f "$d/plan-pass.txt.bak"
hrefused "a record not in runner mode" "$d" "not a runner record"
d="$(hrec big 'host example 1: examples/a' 'plan: budget')"; head -c 5242881 /dev/zero | tr '\0' 'x' >> "$d/plan-refused-hosts.txt"
hrefused "a record file over the size cap" "$d" "plan-refused-hosts.txt is over the size cap"
d="$(hrec link 'host example 1: examples/a' 'plan: budget')"; mv "$d/plan-pass.txt" "$TMP/hr-target.txt"; ln -s "$TMP/hr-target.txt" "$d/plan-pass.txt"
hrefused "a record file that is a symbolic link" "$d" "plan-pass.txt is not a regular file"
d="$TMP/hr-many"; mkdir -p "$d"
{ printf '%s\n' 'plan pass mode: runner' 'plan pass budget: 90 minutes'
  i=1; while [ "$i" -le 15000 ]; do printf 'host example %s: examples/e%s\nplan: budget\n' "$i" "$i"; i=$((i + 1)); done
  echo 'plan summary: 15000 examples, 0 planned, 0 exceptions, 15000 other'; } > "$d/plan-pass.txt"
: > "$d/plan-refused-hosts.txt"
hrefused "an output over the size cap" "$d" "the output is over the size cap"

# host-records.jq's caps on the untrusted block, as github-io.md's Caps states them: the body
# item 8000 bytes, the title and a thread comment 4000, 16000 in total, in block order.
cq() { jq -n -c -L "${PP%/*}" "include \"host-records\";
  [{kind: \"title\", text: (\"t\" * 4100)}, {kind: \"body\", text: (\"b\" * 8200)},
   {kind: \"thread\", text: (\"c\" * 5000)}, {kind: \"thread\", text: \"late\"}, {kind: \"conversation\", text: (\"v\" * 9000)}]
  | capped | $1"; }
check "caps: the title is cut to 4000 bytes" "$([ "$(cq '.[0] | [(.text | length), .omitted]')" = '[4000,100]' ]; echo $?)"
check "caps: the body is cut to 8000 bytes" "$([ "$(cq '.[1] | [(.text | length), .omitted]')" = '[8000,200]' ]; echo $?)"
check "caps: a thread comment gets what is left of the 16000" "$([ "$(cq '.[2] | [(.text | length), .omitted]')" = '[4000,1000]' ]; echo $?)"
check "caps: an item with nothing left travels empty, all omitted" "$([ "$(cq '.[3] | [.text, .omitted]')" = '["",4]' ]; echo $?)"
check "caps: a conversation comment is not cut" "$([ "$(cq '.[4] | [(.text | length), .omitted]')" = '[9000,0]' ]; echo $?)"
# host.json's prose-truncated entries: one per cut item class, body, thread, title, with the
# bytes cut in that class; none when nothing was cut.
check "caps: truncations name each cut class with its bytes" \
  "$([ "$(cq 'truncations')" = '[{"kind":"prose-truncated","item":"body","omitted":200},{"kind":"prose-truncated","item":"thread","omitted":1004},{"kind":"prose-truncated","item":"title","omitted":100}]' ]; echo $?)"
check "caps: no truncation, no entry" "$([ "$(jq -n -c -L "${PP%/*}" 'include "host-records"; [{kind: "body", text: "short"}] | capped | truncations')" = '[]' ]; echo $?)"
# An issue item: 4000 bytes of its own, outside the 16000, so the threads keep their share.
iq() { jq -n -c -L "${PP%/*}" "include \"host-records\";
  [{kind: \"title\", text: (\"t\" * 4000)}, {kind: \"body\", text: (\"b\" * 8000)},
   {kind: \"issue\", text: (\"i\" * 4100)}, {kind: \"issue\", text: \"short\"}, {kind: \"thread\", text: (\"c\" * 4000)}]
  | capped | $1"; }
check "caps: an issue is cut to 4000 bytes" "$([ "$(iq '.[2] | [(.text | length), .omitted]')" = '[4000,100]' ]; echo $?)"
check "caps: issues take nothing from the 16000" "$([ "$(iq '[.[3].omitted, (.[4].text | length), .[4].omitted]')" = '[0,4000,0]' ]; echo $?)"
check "caps: a cut issue has its own prose-truncated entry, last" \
  "$([ "$(iq 'truncations')" = '[{"kind":"prose-truncated","item":"issue","omitted":100}]' ]; echo $?)"
# The issue item: number and title first, origin by numeric id as for a comment.
ii() { jq -n -c -L "${PP%/*}" "include \"host-records\"; $1 | issue_item({typename: \"User\", id: 11, login: \"a\"})"; }
check "issue item: the pull request author's issue is change-author, number and title first" \
  "$([ "$(ii '{number: 1303, title: "T", body: "B", user: {typename: "User", id: 11, login: "x"}}')" = '{"kind":"issue","origin":"change-author","text":"#1303 T\n\nB"}' ]; echo $?)"
check "issue item: another author's issue is other, an empty body adds no blank line" \
  "$([ "$(ii '{number: 2, title: "T", body: "", user: {typename: "User", id: 12, login: "a"}}')" = '{"kind":"issue","origin":"other","text":"#2 T"}' ]; echo $?)"
HV="{\"format\":1,\"repo\":\"o/r\",\"number\":1,\"head_sha\":\"$HH\",\"base_sha\":\"$HH\",\"merge_base\":null,\"prefix\":\"\",
  \"state\":{\"state\":\"open\",\"merged\":false,\"draft\":false,\"base_is_default\":true,\"self_authored\":false,\"locked\":false,\"lock_reason\":null},
  \"signals\":{\"threads\":\"pass\",\"review_decision\":\"none\",\"mergeability\":\"pass\"},\"own_review\":null,
  \"could_not_run\":[],\"unresolved_threads\":[],
  \"conversation\":{\"path\":\"graphql\",\"omitted\":null,\"considered\":0,\"bot_considered\":0,\"counts\":{},\"notes\":[]},
  \"related\":{\"status\":\"ok\",\"open_unlinked\":[],\"sidebar_not_read\":false}}"
hv() { printf '%s' "$HV" | jq -c "$1" | jq -r -L "${PP%/*}" --arg h "$HH" 'include "host-records"; valid_host($h)'; }
check "host.json: the base object is valid" "$([ "$(hv .)" = true ]; echo $?)"
check "host.json: a locked pull request with a reason, or with none, is valid" \
  "$([ "$(hv '.state.locked = true | .state.lock_reason = "resolved"')" = true ] && [ "$(hv '.state.locked = true')" = true ]; echo $?)"
check "host.json: a lock that is not a boolean is refused" \
  "$([ "$(hv '.state.locked = "true"')" = false ] && [ "$(hv '.state.locked = null')" = false ]; echo $?)"
check "host.json: a state without the lock is refused" "$([ "$(hv 'del(.state.locked)')" = false ]; echo $?)"
check "host.json: a lock reason outside GitHub's set, or on an unlocked pull request, is refused" \
  "$([ "$(hv '.state.locked = true | .state.lock_reason = "x"')" = false ] && [ "$(hv '.state.lock_reason = "spam"')" = false ]; echo $?)"
# Negative self-check: a host-records.jq without the boolean test passes a string lock.
mkdir -p "$TMP/hr-mut"
perl -pe 's/and \(\.locked \| type == "boolean"\)/and true/' "${PP%/*}/host-records.jq" > "$TMP/hr-mut/host-records.jq"
check "self-check: the lock's boolean test, removed, lets a string lock through" \
  "$(! cmp -s "${PP%/*}/host-records.jq" "$TMP/hr-mut/host-records.jq" &&
     [ "$(printf '%s' "$HV" | jq -c '.state.locked = "true"' | jq -r -L "$TMP/hr-mut" --arg h "$HH" 'include "host-records"; valid_host($h)')" = true ]; echo $?)"
# host-pass.sh records the lock from the metadata read, its reason only from GitHub's closed set.
LJ="$(sed -n '/locked: (\$meta.locked == true),$/,/else null end)},$/p' "${PP%/*}/host-pass.sh" | sed 's/^ *//; s/},$//')"
lk() { jq -c -n --argjson meta "$1" "{$LJ}"; }
check "host-pass: the lock and its reason come from the metadata" \
  "$([ "$(lk '{"locked": true, "active_lock_reason": "too heated"}')" = '{"locked":true,"lock_reason":"too heated"}' ] &&
     [ "$(lk '{"locked": true, "active_lock_reason": "a `x` reason"}')" = '{"locked":true,"lock_reason":null}' ] &&
     [ "$(lk '{"active_lock_reason": "spam"}')" = '{"locked":false,"lock_reason":null}' ]; echo $?)"
check "host.json: prose-truncated with its item and bytes is valid" \
  "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 200}, {kind: "prose-truncated", item: "thread", omitted: 1}]')" = true ]; echo $?)"
check "host.json: prose-truncated of an issue is valid" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "issue", omitted: 7}]')" = true ]; echo $?)"
check "host.json: a prose-truncated of an older record, kind alone, is valid" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated"}]')" = true ]; echo $?)"
check "host.json: prose-truncated omitting 0 bytes is refused" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 0}]')" = false ]; echo $?)"
check "host.json: prose-truncated omitting negative bytes is refused" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: -5}]')" = false ]; echo $?)"
check "host.json: prose-truncated of an unknown item is refused" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "conversation", omitted: 5}]')" = false ]; echo $?)"
check "host.json: prose-truncated with an item and no bytes is refused" "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "body"}]')" = false ]; echo $?)"
check "host.json: two prose-truncated entries for one item are refused" \
  "$([ "$(hv '.could_not_run = [{kind: "prose-truncated", item: "body", omitted: 2}, {kind: "prose-truncated", item: "body", omitted: 3}]')" = false ]; echo $?)"
# host-pass.sh writes the entries from the capped block, not a bare kind.
check "host-pass: could_not_run takes the truncations of the block" \
  "$(grep -F '+ ($b[0].items | truncations)),' "${PP%/*}/host-pass.sh" > /dev/null; echo $?)"

# The sensitive names of an addresses file, from ADDR_JQ in plan-pass.sh: the same pattern and
# 500 cap as attributes, and never a name the attributes leave out.
AJ="$(sed -n "/^ADDR_JQ='\$/,/^'\$/p" "$PP" | sed '1d;$d')"
aj() { jq -c --arg h "$2" --arg e "${3:-}" "$AJ" <<< "$1"; }
o="$(aj "$(jq -n -c '[range(600) | "a\(1000 + .)"] as $n
  | {resource_changes: [{address: "aws_x.big", change: {after: ($n | map({(.): 1}) | add + {Bad: 1}),
      after_sensitive: ($n | map({(.): true}) | add + {Bad: true})}},
    {address: "aws_x.whole", change: {after: {a: 1, b: null}, after_unknown: {c: true}, after_sensitive: true}}]}')" nosha)"
check "addresses: sensitive names keep the pattern and the 500 cap of the attributes" \
  "$(jq -e '(.attributes["aws_x.big"] | length) == 500 and .sensitive["aws_x.big"] == .attributes["aws_x.big"]' <<< "$o" > /dev/null 2>&1; echo $?)"
check "addresses: an instance wholly sensitive marks every attribute of its address" \
  "$(jq -e '.sensitive["aws_x.whole"] == ["a","c"]' <<< "$o" > /dev/null 2>&1; echo $?)"
check "addresses: no head_sha unless the head is a full SHA" "$(jq -e 'has("head_sha") | not' <<< "$o" > /dev/null 2>&1; echo $?)"
check "addresses: no example without one" "$(jq -e 'has("example") | not' <<< "$o" > /dev/null 2>&1; echo $?)"
for bad in '../x' 'examples/../x' 'examples/a b' 'examples/..'; do
  check "addresses: an example directory outside the pattern is left out ($bad)" \
    "$(aj '{"resource_changes":[]}' nosha "$bad" | jq -e 'has("example") | not' > /dev/null 2>&1; echo $?)"
done
check "addresses: a plain example directory is kept" \
  "$(aj '{"resource_changes":[]}' nosha 'modules/x/examples/a.b_c-d' | jq -e '.example == "modules/x/examples/a.b_c-d"' > /dev/null 2>&1; echo $?)"
# Data sources, on the stub's show JSON: none from a plan that errored, its resource changes kept.
o="$(aj "$(jq -c '. + {errored: true}' "$TMP/show.json")" nosha)"
check "addresses: a plan that errored adds no data source read at plan, only its resource changes" \
  "$(jq -e '.addresses == ["aws_kms_key.this","data.aws_iam_policy_document.deferred","module.s3.aws_s3_bucket.this"]' <<< "$o" > /dev/null 2>&1; echo $?)"
for good in data.a_b.c module.m.data.a_b.c module.m.module.n-2.data.a-b.c_d module.data.a_b.c a_b.data; do
  check "addresses: the address pattern takes $good" \
    "$(aj "{\"resource_changes\":[{\"address\":\"$good\",\"change\":{}}]}" nosha | jq -e --arg a "$good" '.addresses == [$a]' > /dev/null 2>&1; echo $?)"
done
for bad in data.a_b data.data.a.b module.m.data.a module.m a.b.c data..a.b 'data.a.b c'; do
  check "addresses: the address pattern refuses $bad" \
    "$(aj "{\"resource_changes\":[{\"address\":\"$bad\",\"change\":{}}]}" nosha | jq -e '.addresses == []' > /dev/null 2>&1; echo $?)"
done
# Negative self-check of the data source rules: each weakened copy of ADDR_JQ lets its case
# through, and the real one does not.
ad_mut() { # name, perl substitution, jq check on the output that the real ADDR_JQ fails[, input jq]
  local m="$TMP/mut-addr-$1.sh" mj in
  perl -pe "$2" "$PP" > "$m"
  mj="$(sed -n "/^ADDR_JQ='\$/,/^'\$/p" "$m" | sed '1d;$d')"
  in="$(jq -c "${4:-.}" "$TMP/show.json")"
  check "mutation addresses-$1 changes ADDR_JQ" "$([ "$mj" != "$AJ" ]; echo $?)"
  check "mutation addresses-$1 is caught" \
    "$(! aj "$in" nosha | jq -e "$3" > /dev/null 2>&1 &&
       jq -c --arg h nosha --arg e '' "$mj" <<< "$in" | jq -e "$3" > /dev/null 2>&1; echo $?)"
}
ad_mut config-match 's/\| select\(\.a \| IN\(\$cfg\[\]\)\) end\)/end)/' '.addresses | index("data.aws_iam_policy_document.gone")'
ad_mut lookahead 's/\(\?!data\\\\\.\|module\\\\\.\)//' '.addresses | index("data.aws_bad")'
ad_mut nested 's/\(\.after \| if type == "object" then to_entries\[\]/(.after | if type == "object" then (.. | objects | to_entries[])/' \
  '.attributes["data.aws_x.map"] | index("leaked_map_key")'
ad_mut sensitive 's/after_sensitive: \.sensitive_values/after_sensitive: {}/' '.sensitive["data.aws_secretsmanager_secret_version.s"] == []'
ad_mut errored 's/if \$plan\.errored == true then empty else/if false then empty else/' '.addresses | index("data.aws_x.map")' '. + {errored: true}'

# The runner's clean_addresses in run-pass.sh, which writes the record's addresses files: a
# sensitive entry outside its shape is dropped, never emptied, and an old file stays without one.
CA="$(sed -n "/^clean_addresses='/,/'\$/p" "${PP%/*}/plan-runner/run-pass.sh")"
CA="${CA#clean_addresses=\'}"; CA="${CA%\'}"
ca() { jq -c "$CA" <<< "$1"; }
o="$(ca '{"addresses":["aws_a.b"],"attributes":{"aws_a.b":["x"]},"module_calls":{}}')"
check "clean_addresses: an old file without sensitive is accepted, still without it" \
  "$([ "$o" = '{"addresses":["aws_a.b"],"attributes":{"aws_a.b":["x"]},"module_calls":{}}' ]; echo $?)"
o="$(ca '{"addresses":["data.aws_a.b","module.m.data.aws_c.d","data.aws_e","module.m.data.f"],"attributes":{"data.aws_a.b":["json"],"data.aws_e":["x"]},"sensitive":{"data.aws_a.b":["json"]}}')"
check "clean_addresses: data source addresses kept with their names, a malformed data address dropped" \
  "$(jq -e '. == {addresses:["data.aws_a.b","module.m.data.aws_c.d"],attributes:{"data.aws_a.b":["json"]},module_calls:{},sensitive:{"data.aws_a.b":["json"]}}' <<< "$o" > /dev/null 2>&1; echo $?)"
o="$(ca '{"addresses":["aws_a.b","aws_c.d"],"attributes":{"aws_a.b":["x","y"]},"sensitive":{"aws_a.b":["y","x","y"],"aws_c.d":[],"aws_e.f":["x"]}}')"
check "clean_addresses: sensitive kept for planned addresses, sorted, an empty list kept" \
  "$(jq -e '.sensitive == {"aws_a.b":["x","y"],"aws_c.d":[]}' <<< "$o" > /dev/null 2>&1; echo $?)"
for bad in '"x"' '["x"]' 'null'; do
  check "clean_addresses: a sensitive key that is not an object is dropped ($bad)" \
    "$(ca "{\"addresses\":[\"aws_a.b\"],\"sensitive\":$bad}" | jq -e 'has("sensitive") | not' > /dev/null 2>&1; echo $?)"
done
o="$(ca "$(jq -n -c '{addresses: ["aws_a.b","aws_c.d","aws_e.f","aws_g.h","aws_i.j"],
  sensitive: {"aws_a.b": "x", "aws_c.d": ["x","Bad"], "aws_e.f": [1], "aws_g.h": [range(501) | "a\(.)"], "aws_i.j": [range(500) | "a\(.)"]}}')")"
check "clean_addresses: a malformed sensitive entry is dropped, never emptied; 500 names pass, 501 do not" \
  "$(jq -e '.sensitive | keys == ["aws_i.j"] and (.["aws_i.j"] | length) == 500' <<< "$o" > /dev/null 2>&1; echo $?)"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
