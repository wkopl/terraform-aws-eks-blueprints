module "helm_addon" {
  source = "../helm-addon"

  helm_config = merge(
    {
      name             = "nvflare"
      chart            = "${path.module}/chart"
      version          = "0.1.0"
      namespace        = "nvflare"
      create_namespace = true
      description      = "A Helm chart for NVFlare overseer and servers"
    },
    var.helm_config
  )

  # Blueprints
  addon_context = var.addon_context
}
