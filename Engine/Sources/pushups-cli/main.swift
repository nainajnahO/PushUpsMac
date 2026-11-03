import Foundation
import PushUpsEngine

print("pushups-cli — port of the vision-demos push-ups demo at \(PushUpsEngine.referenceCommit.prefix(7))")
usage()

func usage() -> Never {
    print("""
        Usage: pushups-cli
        """)
    exit(1)
}
