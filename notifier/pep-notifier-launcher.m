#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <errno.h>
#import <signal.h>
#import <sqlite3.h>
#import <sys/types.h>
#import <unistd.h>

static NSString *const kAppGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
static NSString *const kAppGroupIdentifier = @"group.software.pEp";
static NSString *const kDatabaseName = @"security.pEp.sqlite";
static const char *kPython = "/var/jb/usr/bin/python3";
static const char *kNotifierScript = "/var/jb/usr/libexec/pep-notifier.py";

static void logLine(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String ?: "pep-notifier: log encoding failure");
    fflush(stderr);
}

static NSString *findDatabasePath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:kAppGroupRoot
                                                            error:&error];
    if (entries == nil) {
        logLine([NSString stringWithFormat:@"credential-loader: app-group scan failed: %@",
                                           error.localizedDescription]);
        return nil;
    }

    for (NSString *entry in entries) {
        NSString *container = [kAppGroupRoot stringByAppendingPathComponent:entry];
        NSString *metadataPath =
            [container stringByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (![metadata[@"MCMMetadataIdentifier"] isEqual:kAppGroupIdentifier]) {
            continue;
        }

        NSString *database = [container stringByAppendingPathComponent:kDatabaseName];
        if ([fm isReadableFileAtPath:database]) {
            return database;
        }
    }

    logLine(@"credential-loader: pEp app-group database was not found");
    return nil;
}

static NSData *passwordForKey(NSString *key, OSStatus *statusOut) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchCaseInsensitive: @YES,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecAttrService: @"Server",
        (__bridge id)kSecAttrAccount: key
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (statusOut != NULL) {
        *statusOut = status;
    }
    if (status != errSecSuccess || result == NULL) {
        if (result != NULL) {
            CFRelease(result);
        }
        return nil;
    }

    return CFBridgingRelease(result);
}

static NSArray<NSDictionary *> *loadAccounts(NSString *databasePath,
                                              NSUInteger *keychainFailures) {
    sqlite3 *database = NULL;
    int openResult = sqlite3_open_v2(databasePath.UTF8String,
                                     &database,
                                     SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                                     NULL);
    if (openResult != SQLITE_OK) {
        logLine([NSString stringWithFormat:@"credential-loader: database open failed: %d",
                                           openResult]);
        if (database != NULL) {
            sqlite3_close(database);
        }
        return nil;
    }

    const char *sql =
        "SELECT s.ZADDRESS, s.ZPORT, c.ZLOGINNAME, c.ZKEY, "
        "COALESCE(s.ZAUTHMETHOD, ''), s.ZTRANSPORTRAWVALUE "
        "FROM ZCDSERVER s "
        "JOIN ZCDSERVERCREDENTIALS c ON s.ZCREDENTIALS = c.Z_PK "
        "WHERE s.ZSERVERTYPERAWVALUE = 0 "
        "AND s.ZADDRESS IS NOT NULL "
        "AND c.ZLOGINNAME IS NOT NULL "
        "AND c.ZKEY IS NOT NULL";

    sqlite3_stmt *statement = NULL;
    int prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, NULL);
    if (prepareResult != SQLITE_OK) {
        logLine([NSString stringWithFormat:@"credential-loader: database query failed: %d",
                                           prepareResult]);
        sqlite3_close(database);
        return nil;
    }

    NSMutableArray<NSDictionary *> *accounts = [NSMutableArray array];
    NSUInteger failures = 0;
    NSUInteger row = 0;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        row += 1;
        const unsigned char *hostBytes = sqlite3_column_text(statement, 0);
        int port = sqlite3_column_int(statement, 1);
        const unsigned char *loginBytes = sqlite3_column_text(statement, 2);
        const unsigned char *keyBytes = sqlite3_column_text(statement, 3);
        const unsigned char *authBytes = sqlite3_column_text(statement, 4);
        int transport = sqlite3_column_int(statement, 5);

        if (hostBytes == NULL || loginBytes == NULL || keyBytes == NULL) {
            failures += 1;
            continue;
        }

        NSString *host = [NSString stringWithUTF8String:(const char *)hostBytes];
        NSString *login = [NSString stringWithUTF8String:(const char *)loginBytes];
        NSString *key = [NSString stringWithUTF8String:(const char *)keyBytes];
        NSString *auth = authBytes == NULL
            ? @""
            : [NSString stringWithUTF8String:(const char *)authBytes];
        OSStatus keychainStatus = errSecSuccess;
        NSData *passwordData = passwordForKey(key, &keychainStatus);
        NSString *password = passwordData == nil
            ? nil
            : [[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding];

        if (password.length == 0) {
            failures += 1;
            logLine([NSString stringWithFormat:
                @"credential-loader: keychain lookup failed for account %lu (status %d)",
                (unsigned long)row, (int)keychainStatus]);
            continue;
        }

        [accounts addObject:@{
            @"host": host,
            @"port": @(port > 0 ? port : 993),
            @"login": login,
            @"password": password,
            @"auth_method": auth ?: @"",
            @"transport": @(transport)
        }];
    }

    sqlite3_finalize(statement);
    sqlite3_close(database);
    if (keychainFailures != NULL) {
        *keychainFailures = failures;
    }
    return accounts;
}

static BOOL writeAll(int fd, const uint8_t *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(fd, bytes + written, length - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return NO;
        }
        written += (size_t)result;
    }
    return YES;
}

static NSMutableData *loadCredentialJSON(NSUInteger *accountCount,
                                         NSUInteger *keychainFailures) {
    NSString *databasePath = findDatabasePath();
    if (databasePath == nil) {
        return nil;
    }

    NSArray<NSDictionary *> *accounts = loadAccounts(databasePath, keychainFailures);
    if (accounts == nil || accounts.count == 0) {
        logLine([NSString stringWithFormat:
            @"credential-loader: no usable IMAP accounts (keychain failures: %lu)",
            (unsigned long)(keychainFailures == NULL ? 0 : *keychainFailures)]);
        return nil;
    }
    if (accountCount != NULL) {
        *accountCount = accounts.count;
    }

    NSDictionary *payload = @{@"version": @1, @"accounts": accounts};
    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:&jsonError];
    if (json == nil) {
        logLine([NSString stringWithFormat:@"credential-loader: JSON failed: %@",
                                           jsonError.localizedDescription]);
        return nil;
    }
    return [json mutableCopy];
}

static int execNotifierWithCredentialLoader(void) {
    signal(SIGCHLD, SIG_IGN);
    int credentialPipe[2];
    if (pipe(credentialPipe) != 0) {
        logLine([NSString stringWithFormat:@"credential-loader: pipe failed: %d", errno]);
        return 5;
    }

    pid_t loader = fork();
    if (loader < 0) {
        close(credentialPipe[0]);
        close(credentialPipe[1]);
        logLine([NSString stringWithFormat:@"credential-loader: fork failed: %d", errno]);
        return 6;
    }

    if (loader == 0) {
        @autoreleasepool {
            close(credentialPipe[0]);
            NSUInteger accountCount = 0;
            NSUInteger keychainFailures = 0;
            NSMutableData *credentialJSON =
                loadCredentialJSON(&accountCount, &keychainFailures);
            if (credentialJSON == nil) {
                close(credentialPipe[1]);
                _exit(73);
            }
            BOOL sent = writeAll(credentialPipe[1],
                                 credentialJSON.bytes,
                                 credentialJSON.length);
            memset(credentialJSON.mutableBytes, 0, credentialJSON.length);
            close(credentialPipe[1]);
            _exit(sent ? 0 : 74);
        }
    }

    close(credentialPipe[1]);
    if (credentialPipe[0] != 3) {
        if (dup2(credentialPipe[0], 3) < 0) {
            close(credentialPipe[0]);
            logLine([NSString stringWithFormat:@"credential-loader: dup2 failed: %d",
                                               errno]);
            return 7;
        }
        close(credentialPipe[0]);
    }
    execl(kPython, kPython, kNotifierScript, "--credentials-fd", "3", NULL);
    logLine([NSString stringWithFormat:@"credential-loader: exec failed: %d", errno]);
    return 8;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--check") == 0) {
            NSUInteger accountCount = 0;
            NSUInteger keychainFailures = 0;
            NSMutableData *credentialJSON =
                loadCredentialJSON(&accountCount, &keychainFailures);
            if (credentialJSON == nil) {
                return 3;
            }
            printf("credential-check: accounts=%lu keychain_failures=%lu\n",
                   (unsigned long)accountCount,
                   (unsigned long)keychainFailures);
            memset(credentialJSON.mutableBytes, 0, credentialJSON.length);
            return keychainFailures == 0 ? 0 : 4;
        }
        return execNotifierWithCredentialLoader();
    }
}
