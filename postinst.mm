#include "CyteKit/UCPlatform.h"

#include <dirent.h>
#include <strings.h>

#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#include <Menes/ObjectHandle.h>

void Finish(const char *finish) {
    if (finish == NULL)
        return;

    const char *cydia(getenv("CYDIA"));
    if (cydia == NULL)
        return;

    int fd([[[[NSString stringWithUTF8String:cydia] componentsSeparatedByString:@" "] objectAtIndex:0] intValue]);

    FILE *fout(fdopen(fd, "w"));
    fprintf(fout, "finish:%s\n", finish);
    fclose(fout);
}

static bool setnsfpn(const char *path) {
    return system([[NSString stringWithFormat:@"/var/jb/usr/libexec/cydia/setnsfpn %s", path] UTF8String]) == 0;
}

enum StashStatus {
    StashDone,
    StashFail,
    StashGood,
};

static StashStatus MoveStash() {
    struct stat stat;

    if (lstat("/var/jb/var/stash", &stat) == -1)
        return errno == ENOENT ? StashGood : StashFail;
    else if (S_ISLNK(stat.st_mode))
        return StashGood;
    else if (!S_ISDIR(stat.st_mode))
        return StashFail;

    if (lstat("/var/jb/var/db/stash", &stat) == -1) {
        if (errno == ENOENT)
            goto move;
        else return StashFail;
    } else if (S_ISLNK(stat.st_mode))
        // XXX: this is fixable
        return StashFail;
    else if (!S_ISDIR(stat.st_mode))
        return StashFail;
    else {
        if (!setnsfpn("/var/jb/var/db/stash"))
            return StashFail;
        if (system("mv -t /var/jb/var/stash /var/jb/var/db/stash/*") != 0)
            return StashFail;
        if (rmdir("/var/jb/var/db/stash") == -1)
            return StashFail;
    } move:

    if (!setnsfpn("/var/jb/var/stash"))
        return StashFail;

    if (rename("/var/jb/var/stash", "/var/jb/var/db/stash") == -1)
        return StashFail;
    if (symlink("/var/jb/var/db/stash", "/var/jb/var/stash") != -1)
        return StashDone;
    if (rename("/var/jb/var/db/stash", "/var/jb/var/stash") != -1)
        return StashFail;

    fprintf(stderr, "/var/jb/var/stash misplaced -- DO NOT REBOOT\n");
    return StashFail;
}

static bool FixProtections() {
    const char *path("/var/jb/var/lib");
    mkdir(path, 0755);
    if (!setnsfpn(path)) {
        fprintf(stderr, "failed to setnsfpn %s\n", path);
        return false;
    }

    return true;
}

static void FixPermissions() {
    DIR *stash(opendir("/var/jb/var/stash"));
    if (stash == NULL)
        return;

    while (dirent *entry = readdir(stash)) {
        const char *folder(entry->d_name);
        if (strlen(folder) != 8)
            continue;
        if (strncmp(folder, "_.", 2) != 0)
            continue;

        char path[1024];
        sprintf(path, "/var/jb/var/stash/%s", folder);

        struct stat stat;
        if (lstat(path, &stat) == -1)
            continue;
        if (!S_ISDIR(stat.st_mode))
            continue;

        chmod(path, 0755);
    }

    closedir(stash);
}

#define APPLICATIONS "/var/jb/Applications"
static bool FixApplications() {
    char target[1024];
    ssize_t length(readlink(APPLICATIONS, target, sizeof(target)));
    if (length == -1)
        return false;

    if (length >= sizeof(target)) // >= "just in case" (I'm nervous)
        return false;
    target[length] = '\0';

    if (strlen(target) != 30)
        return false;
    if (memcmp(target, "/var/jb/var/stash/Applications.", 24) != 0)
        return false;
    if (strchr(target + 24, '/') != NULL)
        return false;

    struct stat stat;
    if (lstat(target, &stat) == -1)
        return false;
    if (!S_ISDIR(stat.st_mode))
        return false;

    char temp[] = "/var/jb/var/stash/_.XXXXXX";
    if (mkdtemp(temp) == NULL)
        return false;

    if (false) undo: {
        unlink(temp);
        return false;
    }

    if (chmod(temp, 0755) == -1)
        goto undo;

    char destiny[strlen(temp) + 32];
    sprintf(destiny, "%s%s", temp, APPLICATIONS);

    if (unlink(APPLICATIONS) == -1)
        goto undo;

    if (rename(target, destiny) == -1) {
        if (symlink(target, APPLICATIONS) == -1)
            fprintf(stderr, "/var/jb/Applications damaged -- DO NOT REBOOT\n");
        goto undo;
    } else {
        bool success;
        if (symlink(destiny, APPLICATIONS) != -1)
            success = true;
        else {
            fprintf(stderr, "/var/jb/var/stash/Applications damaged -- DO NOT REBOOT\n");
            success = false;
        }

        // unneccessary, but feels better (I'm nervous)
        symlink(destiny, target);

        [@APPLICATIONS writeToFile:[NSString stringWithFormat:@"%s.lnk", temp] atomically:YES encoding:NSNonLossyASCIIStringEncoding error:NULL];
        return success;
    }
}

int main(int argc, const char *argv[]) {
    if (argc < 2 || strcmp(argv[1], "configure") != 0)
        return 0;

    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    bool restart(false);

    if (kCFCoreFoundationVersionNumber >= 1000) {
        if (!FixProtections())
            return 1;
        switch (MoveStash()) {
            case StashDone:
                restart = true;
                break;
            case StashFail:
                fprintf(stderr, "failed to move stash\n");
                return 1;
            case StashGood:
                break;
        }
    }

    #define OldCache_ "/var/root/Library/Caches/com.saurik.Cydia"
    if (access(OldCache_, F_OK) == 0)
        system("rm -rf " OldCache_);

    #define NewCache_ "/var/mobile/Library/Caches/com.saurik.Cydia"
    system("cd /; su -c 'mkdir -p " NewCache_ "' mobile");
    if (access(NewCache_ "/lists", F_OK) != 0 && errno == ENOENT)
        system("cp -at " NewCache_ " /var/jb/var/lib/apt/lists");
    system("chown -R 501.501 " NewCache_);

    #define OldLibrary_ "/var/jb/var/lib/cydia"

    #define NewLibrary_ "/var/jb/var/mobile/Library/Cydia"
    system("cd /; su -c 'mkdir -p " NewLibrary_ "' mobile");

    #define Cytore_ "/metadata.cb0"

    #define CYDIA_LIST "/var/jb/etc/apt/sources.list.d/cydia.list"
    unlink(CYDIA_LIST);
    [[NSString stringWithFormat:@
        "deb http://apt.saurik.com/ ios/%.2f main\n"
        "deb http://apt.thebigboss.org/repofiles/cydia/ stable main\n"
        "deb http://cydia.zodttd.com/repo/cydia/ stable main\n"
        "deb http://apt.modmyi.com/ stable main\n"
        "deb http://repo.cypwn.xyz/ stable main\n"
    , kCFCoreFoundationVersionNumber] writeToFile:@ CYDIA_LIST atomically:YES];

    if (access(NewLibrary_ Cytore_, F_OK) != 0 && errno == ENOENT) {
        if (access(NewCache_ Cytore_, F_OK) == 0)
            system("mv -f " NewCache_ Cytore_ " " NewLibrary_);
        else if (access(OldLibrary_ Cytore_, F_OK) == 0)
            system("mv -f " OldLibrary_ Cytore_ " " NewLibrary_);
        chown(NewLibrary_ Cytore_, 501, 501);
    }

    FixPermissions();

    restart |= FixApplications();

    if (restart)
        Finish("restart");

    [pool release];
    return 0;
}
