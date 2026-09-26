# week7-github-role.tf — new file, own folder is fine, run once tonight

provider "aws" {
  region = "eu-north-1"
}

data "aws_caller_identity" "current" {}

# The OIDC provider already exists in this account (created in Week 5/6) —
# looked up, not recreated.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "week7_deploy" {
  name = "week7-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Replace <ownerID> / <repoID> with real values — get them with:
          # gh api repos/EbotProg/Learning-Devops-Week-3-Docker-Deep-Dive --jq '.owner.id, .id'
          "token.actions.githubusercontent.com:sub" = "repo:EbotProg@*/Learning-Devops-Week-3-Docker-Deep-Dive@*:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.week7_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]
        Resource = [
          "arn:aws:ecr:eu-north-1:${data.aws_caller_identity.current.account_id}:repository/crud-nextjs-frontend",
          "arn:aws:ecr:eu-north-1:${data.aws_caller_identity.current.account_id}:repository/crud-parse-server-backend"
        ]
      }
    ]
  })
}

output "week7_role_arn" {
  value = aws_iam_role.week7_deploy.arn
}