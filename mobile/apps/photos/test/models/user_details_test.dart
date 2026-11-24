import "package:flutter_test/flutter_test.dart";
import "package:photos/models/user_details.dart";

const _gb = 1 << 30;

const _familyDetails =
    '''
{
  "email": "member@example.org",
  "usage": ${3 * _gb},
  "fileCount": 12,
  "storageBonus": ${10 * _gb},
  "subscription": {
    "productID": "free",
    "storage": ${10 * _gb},
    "originalTransactionID": "",
    "paymentProvider": "",
    "expiryTime": 1,
    "price": "",
    "period": ""
  },
  "familyData": {
    "storage": ${200 * _gb},
    "expiryTime": 1,
    "members": [
      {
        "id": "admin",
        "userID": 1,
        "email": "admin@example.org",
        "isAdmin": true,
        "status": "SELF",
        "usage": ${200 * _gb}
      },
      {
        "id": "member",
        "userID": 2,
        "email": "member@example.org",
        "isAdmin": false,
        "status": "ACCEPTED",
        "usage": ${3 * _gb},
        "storageLimit": ${5 * _gb}
      }
    ]
  },
  "profileData": {"isTwoFactorEnabled": true}
}
''';

void main() {
  test("older cached details retain family totals and the member cap", () {
    final details = UserDetails.fromJson(_familyDetails);

    expect(details.getTotalStorage(), 210 * _gb);
    expect(details.getFamilyOrPersonalUsage(), 203 * _gb);
    expect(details.getFreeStorage(), 2 * _gb);
  });

  test("cached Rust totals survive an offline read with profile details", () {
    final fetched = UserDetails.fromJson(
      _familyDetails,
      storage: (totalBytes: 211 * _gb, usedBytes: 210 * _gb),
    );
    final cached = UserDetails.fromJson(fetched.toJson());

    expect(cached.getTotalStorage(), 211 * _gb);
    expect(cached.getFamilyOrPersonalUsage(), 210 * _gb);
    expect(cached.getFreeStorage(), 2 * _gb);
    expect(cached.fileCount, 12);
    expect(cached.profileData?.isTwoFactorEnabled, isTrue);
    expect(cached.currentFamilyMember()?.userID, 2);
  });
}
