module "helm_addon" {
  source = "../helm-addon"

  helm_config = merge(
    {
      name             = "nvflare"
      chart            = "${path.module}/chart"
      version          = "0.2.0"
      namespace        = "nvflare"
      create_namespace = true
      description      = "A Helm chart for NVFlare overseer and servers"
      values = [
        <<-EOT
        overseer:
          image:
            repository: ${var.helm_config.overseer_image_repository}
            tag: ${var.helm_config.overseer_image_tag}

        server:
          image:
            repository: ${var.helm_config.server_image_repository}
            tag: ${var.helm_config.server_image_tag}
        EOT
      ]
    },
    var.helm_config
  )

  # Blueprints
  addon_context = var.addon_context
}
