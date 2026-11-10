idf_component_register(SRCS "main.c" "ancs_proto.c" "serial_link.c" "hfp.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt nvs_flash esp_driver_uart esp_timer esp_app_format)
