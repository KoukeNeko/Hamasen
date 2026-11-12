# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Interface text. The English string is the key; a locale with a table here
gets that table, every other locale gets English."""
import json
import os

from gi.repository import GLib

TRADITIONAL_CHINESE = {
    "Hamasen": "Hamasen 哈瑪星",
    "Server": "伺服器",
    "Add Server": "新增伺服器",
    "No Servers": "沒有伺服器",
    "Name": "名稱",
    "Protocol": "通訊協定",
    "Host": "主機",
    "Port": "連接埠",
    "Region": "區域",
    "User": "使用者",
    "Password": "密碼",
    "Path": "路徑",
    "Export": "匯出路徑",
    "Endpoint (optional)": "端點（選填）",
    "Access Key ID": "存取金鑰 ID",
    "Secret Access Key": "私密存取金鑰",
    "Bucket": "儲存貯體",
    "Path (SMB requires a share)": "路徑（SMB 須指定共用資料夾）",
    "Mount at Login": "登入時掛載",
    "Use Own Client ID": "使用自己的用戶端 ID",
    "Client ID": "用戶端 ID",
    "Client Secret": "用戶端密鑰",
    "1. Create a project in Google Cloud Console.\n"
    "2. Under APIs & Services > Library, enable the Google Drive API.\n"
    "3. Configure the OAuth consent screen and add the account in use as a test user.\n"
    "4. Under Credentials, create an OAuth client ID of type Desktop app.\n"
    "5. Enter the client ID and secret in the fields above.":
        "1. 於 Google Cloud Console 建立專案。\n"
        "2. 於「API 和服務」→「程式庫」啟用 Google Drive API。\n"
        "3. 設定「OAuth 同意畫面」，並將所使用的帳戶加入測試使用者。\n"
        "4. 於「憑證」建立「OAuth 用戶端 ID」，應用程式類型選擇「電腦版應用程式」。\n"
        "5. 將用戶端 ID 與密鑰填入上方欄位。",
    "Open Google Cloud Console": "開啟 Google Cloud Console",
    "Cancel": "取消",
    "Save": "儲存",
    "Close": "關閉",
    "Authorizing": "授權中",
    "Cannot Authorize {service}": "無法授權 {service}",
    "Import from SSH Config": "從 SSH 設定匯入",
    "Start at Login": "登入時啟動",
    "{count} servers imported": "已匯入 {count} 台伺服器",
    "Edit": "編輯",
    "Delete": "刪除",
    "Delete “{name}”?": "刪除「{name}」？",
    "Open": "開啟",
    "Mount": "掛載",
    "Unmount": "卸載",
    "Connecting": "連線中",
    "{service} · Uploading {count}": "{service} · 上傳中 {count}",
    "Open Hamasen": "開啟 Hamasen",
    "Quit": "結束",
    "Connection Lost": "連線中斷",
    "Uploads Complete": "上傳完成",
    "Cannot Connect to “{name}”": "無法連線「{name}」",
    "Specify the share name in the Path field.": "請於「路徑」欄位指定共用資料夾名稱。",
    "The host did not respond. Check the host, port and network connection.":
        "主機未回應。請確認主機、連接埠與網路連線。",
    "Unmount “{name}”?": "卸載「{name}」？",
    "{count} files have not been uploaded yet.": "{count} 個檔案尚未上傳。",
    "Unmount Anyway": "仍要卸載",
    "Language": "語言",
    "Automatic": "自動",
    "Restart Hamasen to apply the language": "重新啟動 Hamasen 以套用語言",
}

TABLES = {"zh_TW": TRADITIONAL_CHINESE, "zh_HK": TRADITIONAL_CHINESE, "zh_MO": TRADITIONAL_CHINESE,
          "zh_Hant": TRADITIONAL_CHINESE}


SETTINGS = os.path.join(GLib.get_user_config_dir(), "hamasen", "settings.json")
LANGUAGES = {"auto": None, "en": "en", "zh_TW": "zh_TW"}  # setting value -> locale it forces


def saved_language():
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            return json.load(f).get("language", "auto")
    except (FileNotFoundError, ValueError):
        return "auto"


def save_language(language):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump({"language": language}, f)


def _table():
    forced = LANGUAGES.get(saved_language())
    names = [forced] if forced else [os.environ.get("HAMASEN_LANG", "")] + list(GLib.get_language_names())
    for name in names:
        language = name.split(".")[0].split("@")[0]
        if language in TABLES:
            return TABLES[language]
        if language and language != "C":
            return {}
    return {}


TABLE = _table()


def _(text):
    return TABLE.get(text, text)
