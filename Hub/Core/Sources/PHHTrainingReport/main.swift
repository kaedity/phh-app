import Foundation
import PHHHubCore
// 取得済みファイルを読み、抽出結果だけstdoutへ返す。認証/API/書込は行わない。
let args=Array(CommandLine.arguments.dropFirst()),allowed:Set<String>=["--input","--from","--to","--cycle","--exercise","--metric","--offset","--limit","--notes"]
do {
    var options:[String:String]=[:],i=0
    while i<args.count { let key=args[i];guard allowed.contains(key),options[key]==nil else { throw HubError.invalidOperation };if key=="--notes" { options[key]="true";i+=1 } else { guard i+1<args.count,!args[i+1].hasPrefix("--") else { throw HubError.invalidOperation };options[key]=args[i+1];i+=2 } }
    guard let path=options["--input"],let from=options["--from"],let to=options["--to"],let metric=TrainingMetric(rawValue:options["--metric"] ?? "使用重量"),let limit=Int(options["--limit"] ?? "20"),let offset=Int(options["--offset"] ?? "0") else { throw HubError.invalidOperation }
    let url=URL(fileURLWithPath:path),size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max;guard size<=50_000_000 else { throw HubError.invalidResponse }
    let snapshot=try JSONDecoder().decode(TrainingExport.self,from:Data(contentsOf:url))
    let data=try snapshot.report(from:from,to:to,cycle:options["--cycle"],exercise:options["--exercise"],metric:metric,offset:offset,limit:limit,includeNotes:options["--notes"] != nil)
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data("\n".utf8))
} catch { FileHandle.standardError.write(Data("取得・抽出失敗：\(error.localizedDescription)\n".utf8));exit(1) }
