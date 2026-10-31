/// CBETA 資料服務（cbdata.dila.edu.tw）請求調用方在 HTTP header 帶上
/// Referer 以便其做存取統計；帶上可歸屬的來源也能避免正常流量被
/// 風控辨識為匿名爬蟲。切記不要偽造官方網站的 Referer。
const cbetaApiHeaders = <String, String>{
  'Referer': 'https://github.com/undcloud/cbeta',
};
