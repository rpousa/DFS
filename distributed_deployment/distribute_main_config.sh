for nf in nrf amf smf upf udm udr ausf pcf nssf; do
  rm -f configs/$nf/config.yaml
  cp configs/main_config/config.yaml configs/$nf/config.yaml
done