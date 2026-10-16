variable "region" {
  description = "デプロイ先のリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "リソース名の接頭辞とタグに使う名前"
  type        = string
  default     = "wf-proto"
}

variable "availability_zones" {
  description = "Private Subnet を置く AZ（Network Connector は 2 つ以上の AZ が必要）。先頭の AZ に NAT Gateway を置く"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Network Connector には 2 つ以上の AZ が必要です。"
  }
}

variable "vpc_cidr" {
  description = "VPC の CIDR。既存 VPC とはつながらないが、混乱を避けるため別の値にしておく"
  type        = string
  default     = "10.200.0.0/16"
}

variable "domain_name" {
  description = "アプリの独自ドメイン"
  type        = string
  default     = "wf.dev.id.basicinc.jp"
}

variable "hosted_zone_name" {
  description = "独自ドメインのレコードを追加する Route 53 のパブリックホストゾーン（既存）"
  type        = string
  default     = "id.basicinc.jp"
}

variable "web_function_name" {
  description = "Web Function の名前（関数本体は GitHub Actions が作る）"
  type        = string
  default     = "wf-proto-todo"
}

variable "web_function_endpoint_domain" {
  description = "Web Function のエンドポイントのホスト名（例: xxxx.yyy.lambda-web.ap-northeast-1.on.aws）。初回デプロイの後に設定すると CloudFront が作られる"
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "デプロイを許可する GitHub リポジトリ（owner/repo）"
  type        = string
  default     = "zaru/lambda-wf-nextjs"
}

variable "github_oidc_sub_prefix" {
  description = <<-EOT
    GitHub の OIDC トークンの sub の接頭辞。リポジトリが不変の ID を使う形式（use_immutable_subject）なので、
    owner@<owner_id>/repo@<repo_id> になる。値は次のコマンドの sub_claim_prefix で確認できる:
    gh api repos/<owner>/<repo>/actions/oidc/customization/sub
  EOT
  type        = string
  default     = "repo:zaru@235650/lambda-wf-nextjs@1421610968"
}

variable "valkey_major_engine_version" {
  description = "ElastiCache Serverless の Valkey のメジャーバージョン"
  type        = string
  default     = "9"
}

variable "valkey_max_data_storage_gb" {
  description = "Valkey のデータ量の上限（GB）"
  type        = number
  default     = 1
}

variable "valkey_max_ecpu_per_second" {
  description = "Valkey の ECPU の上限（毎秒）。負荷試験で頭打ちにならないよう、余裕を持たせる"
  type        = number
  default     = 50000
}
