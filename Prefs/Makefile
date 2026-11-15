TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := Clock26Prefs

Clock26Prefs_FILES := Clock26RootListController.m
Clock26Prefs_FRAMEWORKS := UIKit
Clock26Prefs_PRIVATE_FRAMEWORKS := Preferences
Clock26Prefs_INSTALL_PATH := /Library/PreferenceBundles
Clock26Prefs_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
