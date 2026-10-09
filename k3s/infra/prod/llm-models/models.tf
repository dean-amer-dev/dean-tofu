# The model catalog. Adding a model = one entry here + tofu apply.
# The key is the InferenceService name and the ModelRouter backend name; clients call
# http://llm-router-proxy.llm.svc.cluster.local:8080/v1 with "model" set to the served id.
# Runbook: Obsidian Documentation/infra/adding-an-llm-model.md

locals {
  # murderbot (CUDA, NInfer runtime). The container downloads MODEL_URL itself.
  # Served id = model_id.
  cuda_models = {
    "qwen38-27b" = {
      model_name = "qwen38-27b-nvfp4-ninfer"
      model_id   = "qwen3.8-27b"
      repo       = "neroued/Qwen3.8-27B-nvfp4-NInfer"
      revision   = "3b84117e0fd258b45bd79778ec8d8f27a4ab3d56"
      file       = "qwen3_8_27b_nvfp4.ninfer"
      sha256     = "bb3360522a06e136e0367f5703414d26272b7285c8a6ab6194135c17dbd81b32"
      cache_dir  = "qwen3.8-27b"
      replicas   = 1
    }
    "qwen38-27b-uncensored" = {
      model_name = "qwen38-27b-hauhau-ninfer"
      model_id   = "qwen3.8-27b-uncensored"
      repo       = "WaveCut/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-DFlash2-NInfer-v3"
      revision   = "aa777ba5f8ee7875a575baeb978abbad0d03f47b"
      file       = "qwen3_8_27b_hauhaucs_aggressive_dflash2.ninfer"
      sha256     = "e2f2b0dbd5a23085d21cec99894074f392b51934cd45a282f5c04b08a6fa18a8"
      cache_dir  = "qwen3.8-27b-hauhau"
      replicas   = 0
    }
  }

  # mac-mini-m4 (Metal, oMLX runtime). The repo must also be staged on the mini by Ansible
  # (ansible-playbooks group_vars/macmini_hosts.yml llmkube_models): the agent does not download
  # MLX models. Served id = the repo's base name.
  metal_models = {
    "modernbert-embed-mini" = {
      model_name = "modernbert-embed-mlx"
      repo       = "mlx-community/nomicai-modernbert-embed-base-8bit"
      replicas   = 1
    }
    "qwen35-9b-uncensored-mini" = {
      model_name = "qwen35-9b-hauhau-mlx"
      repo       = "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4"
      replicas   = 1
    }
  }
}
