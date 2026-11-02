# Security

## The labs are insecure on purpose, in specific places

Several labs in this repo plant a weakness, such as an over-broad role assignment or a public
endpoint, because the demo exists to find it and recommend the fix. Each module README names what's
planted. Deploy them only in a subscription and a tenant you use for learning, and remove them the
same day with the lab's own remove command.

That planted weakness is the lesson, so please don't report it as a vulnerability.

## Reporting something real

If you find something that shouldn't be in a public repository, such as a credential, a real
tenant or subscription identifier, or personal information, please don't open a public issue.
Use GitHub's private vulnerability reporting on this repository instead (the **Security** tab, then
**Report a vulnerability**), and I'll fix it and rewrite what's needed.

For a bug in a lab script that could damage resources it didn't create, a private report is the
right channel too.
