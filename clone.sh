#!/bin/bash

git clone https://github.com/tillua467-s-Playground/android_device_xiaomi_phoenix device/xiaomi/phoenix

git clone https://github.com/tillua467-s-Playground/android_device_xiaomi_sm6150-common device/xiaomi/sm6150-common

git clone https://github.com/tillua467-s-Playground/android_kernel_xiaomi_phoenix kernel/xiaomi/sm6150

git clone https://github.com/tillua467-s-Playground/proprietary_vendor_xiaomi_phoenix vendor/xiaomi/phoenix

git clone https://github.com/tillua467-s-Playground/proprietary_vendor_xiaomi_sm6150-common vendor/xiaomi/sm6150-common || { echo "Failed to clone common vendor phoenix"; exit 1; }

git clone https://github.com/tillua467-s-Playground/android_hardware_xiaomi hardware/xiaomi

git clone https://gitlab.com/Shripal17/vendor_xiaomi_miuicamera vendor/xiaomi/miuicamera
